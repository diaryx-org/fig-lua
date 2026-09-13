//! A fig format written in Lua.
//!
//! [`LuaLanguage`] is a [`fig::language::Language`] whose parser and printer
//! are functions in a `.lua` script, run on a Lua 5.4 built into this crate.
//! What a script is — the table it returns, the shape of a node table, the
//! `fig` global it may use — is documented in [`script`]; what the crate does
//! with one is two things:
//!
//! - the `fig-lua` binary serves a script to a `fig` command line as a
//!   helper process, over [`fig::helper::serve`] — the out-of-process
//!   carrier of fig's runtime-language contract;
//! - a Rust program registers one in-process with
//!   [`fig::language::register`], and it is then a [`fig::Format`] every
//!   entry point of the `fig` crate accepts.
//!
//! The two are the same [`Language`]; the wire the binary speaks is the
//! `fig::helper` module's, and the JSON shapes it documents are the shapes a
//! script returns, as Lua tables.
//!
//! ```no_run
//! use fig::{Document, Format};
//! use fig_lua::LuaLanguage;
//!
//! let lang = LuaLanguage::from_file("languages/dotenv.lua")?;
//! let lua_dotenv = fig::language::register(lang)?[0];
//! let doc = Document::parse(b"A=1\n", lua_dotenv)?;
//! assert_eq!(doc.serialize(Format::Json)?, "{\n  \"A\": \"1\"\n}\n");
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

use std::path::Path;
use std::sync::Mutex;

use fig::Value;
use fig::helper::{description_from_value, table_from_value, table_to_value};
use fig::language::{
    Description, Language, LanguageError, NodeTable, PrintOptions, RenderArgs, Renderer,
};
use mlua::{Function, Lua, RegistryKey, Table};

pub mod convert;
pub mod script {
    //! What a fig-lua script is.
    //!
    //! A script is a Lua chunk that returns a table describing the format —
    //! the same fields, with the same names and values, as the `description`
    //! a helper answers `describe` with (see `fig::helper`), plus the
    //! functions the format is:
    //!
    //! ```lua
    //! local M = {}
    //! M.name = "lua-dotenv"
    //! M.caps = { read = true, edit = true, serialize = true }
    //! M.max_mapping_depth = 0
    //! M.syntax = { comments = "hash", kv_sep = "=", empty_map_literal = "{}" }
    //! M.dialects = { { name = "lua-dotenv", extensions = { "env" }, splice = "raw", empty_doc_seed = "" } }
    //! M.samples = { "A=1\n" }
    //! M.renderers = { "value" }
    //!
    //! function M.parse(dialect, input) ... end
    //! function M.print(dialect, t, options) ... end
    //! function M.render(which, args) ... end
    //! return M
    //! ```
    //!
    //! `parse(dialect, input)` takes the input as a Lua string (bytes) and
    //! returns either a **tree** — nodes built with `fig.mapping`,
    //! `fig.sequence`, `fig.entry` and `fig.scalar`, holding their children
    //! and comments as fields, which the prelude lays out in pre-order — or
    //! a **node table** built with `fig.table()` and `t:row(...)`, or any
    //! table of the same shape: `rows` in pre-order, each
    //! `{kind=, parent=, span={s,e}, text=, ...}` with `parent` a 0-based
    //! row id or nil for the root; `comments`, `regions`, `mentions`. To
    //! refuse the input it calls `fig.fail(message, byte_offset)`, from
    //! anywhere; any other error it raises is reported without an offset.
    //! Most scripts write neither by hand: `require("fig.grammar")` is a
    //! set of rules whose results are these nodes, and `G.document{...}`
    //! is a `parse` function.
    //!
    //! `print(dialect, t, options)` receives a node table indexed by
    //! `fig.index` — every row has `id`, `children` (ids), `items` (rows),
    //! `leading`, `trailing` and `dangling`; a keyvalue row has `key` and
    //! `value`; `t.byid(id)` finds a row — and `options` as
    //! `{pretty=, strip_comments=, indent=, width=}`. It returns the
    //! document as a string; `fig.writer(options)` is a buffer that knows
    //! the options. A table whose root is a scalar is a fragment the
    //! editor will splice: spell it as the scalar stands alone.
    //!
    //! `render(which, args)` answers one of the renderers `M.renderers`
    //! declares — `which` is "value", "entry", "item", "tail" or "key" —
    //! given `{dialect=, indent=, key=, value=, literal=, old_key=}`, and
    //! returns the fragment as a string. `literal` is what fig's
    //! bare-literal rules made of `value`: "null", "bool", "int", "float",
    //! "datetime" or "string" — classified by fig, so a script spells the
    //! kind it is told and never decides one.
    //!
    //! Offsets are byte offsets into the input, 0-based and `[start, end)`,
    //! as the wire's are; `fig.scanner` speaks them, so a script converts
    //! Lua's 1-based `i` with `i - 1` only below it. `languages/json.lua`,
    //! `languages/toml.lua`, `languages/ini.lua`, `languages/dotenv.lua`,
    //! `languages/plist.lua` and `languages/canonical.lua` in this
    //! repository are complete scripts; the `fig` global is
    //! `src/prelude.lua`, and `src/grammar.lua` and `src/xml.lua` are the
    //! modules.
}

/// The `fig` global every script sees.
const PRELUDE: &str = include_str!("prelude.lua");

/// The modules a script may `require`, by name.
const MODULES: &[(&str, &str)] = &[
    ("fig.grammar", include_str!("grammar.lua")),
    ("fig.xml", include_str!("xml.lua")),
];

/// A format whose parser and printer are a Lua script.
#[derive(Debug)]
pub struct LuaLanguage {
    /// One Lua state per language, locked around every call: a `Language`
    /// is `Send + Sync`, and Lua is neither on its own.
    lua: Mutex<Lua>,
    /// The table the script returned, held in the registry.
    module: RegistryKey,
    /// Read from the module once, at load; what `describe` answers.
    description: Description,
}

/// Why a script could not be loaded. A failure inside `parse`, `print` or
/// `render` is a [`LanguageError`] instead, reported through the contract.
#[derive(Debug)]
pub enum Error {
    /// The file could not be read.
    Io(std::io::Error),
    /// The chunk did not run to a table, or the table is not a description.
    Script(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(e) => write!(f, "{e}"),
            Error::Script(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

impl LuaLanguage {
    /// Load the script at `path`.
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self, Error> {
        let path = path.as_ref();
        let source = std::fs::read_to_string(path)?;
        Self::from_source(&path.display().to_string(), &source)
    }

    /// Load a script from its text; `name` is what an error message calls
    /// it.
    pub fn from_source(name: &str, source: &str) -> Result<Self, Error> {
        let lua = Lua::new();
        let prelude: Table = lua
            .load(PRELUDE)
            .set_name("fig")
            .eval()
            .map_err(|e| Error::Script(format!("prelude: {e}")))?;
        lua.globals()
            .set("fig", prelude)
            .map_err(|e| Error::Script(e.to_string()))?;
        // The modules a script `require`s, embedded: `package.preload` is
        // consulted before any search path, so no file is looked for.
        let preload: Table = lua
            .globals()
            .get::<Table>("package")
            .and_then(|p| p.get("preload"))
            .map_err(|e| Error::Script(e.to_string()))?;
        for (module_name, source) in MODULES {
            let loader = lua
                .load(*source)
                .set_name(*module_name)
                .into_function()
                .map_err(|e| Error::Script(format!("{module_name}: {e}")))?;
            preload
                .set(*module_name, loader)
                .map_err(|e| Error::Script(e.to_string()))?;
        }
        let module: Table = lua
            .load(source)
            .set_name(name)
            .eval()
            .map_err(|e| Error::Script(format!("{name}: {e}")))?;
        let description_value = convert::lua_to_value(&mlua::Value::Table(module.clone()))
            .map_err(|e| Error::Script(format!("{name}: {e}")))?;
        let description = description_from_value(&description_value)
            .map_err(|e| Error::Script(format!("{name}: {}", e.message)))?;
        let module = lua
            .create_registry_value(module)
            .map_err(|e| Error::Script(e.to_string()))?;
        Ok(LuaLanguage {
            lua: Mutex::new(lua),
            module,
            description,
        })
    }

    /// What the script declared, as loaded.
    pub fn description(&self) -> &Description {
        &self.description
    }

    /// The script's function `name`, or an error naming what is missing.
    fn function(&self, lua: &Lua, name: &str) -> Result<Function, LanguageError> {
        let module: Table = lua
            .registry_value(&self.module)
            .map_err(|e| LanguageError::new(e.to_string()))?;
        let f: Option<Function> = module
            .get(name)
            .map_err(|e| LanguageError::new(e.to_string()))?;
        f.ok_or_else(|| LanguageError::new(format!("the script has no `{name}` function")))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Lua> {
        // A panic inside a Lua call is caught by fig's thunks; the state is
        // still usable for the next call.
        self.lua.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// A Lua error as the contract's error: the script's own `error("…")`
/// message, without the position Lua prefixes it with or the traceback
/// mlua appends.
fn lua_error(e: mlua::Error) -> LanguageError {
    match e {
        mlua::Error::RuntimeError(m) => LanguageError::new(script_message(&m)),
        other => LanguageError::new(other.to_string()),
    }
}

fn script_message(raw: &str) -> String {
    let first = raw.split("\nstack traceback:").next().unwrap_or(raw);
    // `[string "name"]:12: message` — what `error("message")` at level 1
    // produces. A script that wants no position uses `error(msg, 0)`.
    let stripped = first
        .strip_prefix("[string \"")
        .and_then(|rest| rest.split_once("\"]:"))
        .and_then(|(_, rest)| rest.split_once(": "))
        .filter(|(line, _)| line.chars().all(|c| c.is_ascii_digit()))
        .map(|(_, message)| message);
    stripped.unwrap_or(first).to_owned()
}

impl Language for LuaLanguage {
    fn describe(&self) -> Description {
        self.description.clone()
    }

    fn parse(&self, dialect: &str, input: &[u8]) -> Result<NodeTable, LanguageError> {
        let lua = self.lock();
        let parse = self.function(&lua, "parse")?;
        let input = lua
            .create_string(input)
            .map_err(|e| LanguageError::new(e.to_string()))?;
        // Through the prelude's runner, which catches a `fig.fail` and
        // lays a returned tree out as a table.
        let run_parse: Function = lua
            .globals()
            .get::<Table>("fig")
            .and_then(|fig| fig.get("run_parse"))
            .map_err(|e| LanguageError::new(e.to_string()))?;
        let results: mlua::MultiValue =
            run_parse.call((parse, dialect, input)).map_err(lua_error)?;
        let mut results = results.into_iter();
        match results.next() {
            Some(mlua::Value::Table(t)) => {
                let v = convert::lua_to_value(&mlua::Value::Table(t))?;
                let mut table = table_from_value(&v)?;
                // The contract wants comments grouped by row; a script
                // binds them in whatever order it meets them.
                table.comments.sort_by_key(|c| c.node);
                Ok(table)
            }
            // `nil, message, byte_offset`: the refusal convention.
            Some(mlua::Value::Nil) | None => {
                let message = match results.next() {
                    Some(mlua::Value::String(s)) => s.to_string_lossy().to_string(),
                    _ => "the script's parse returned nil without a message".to_owned(),
                };
                let offset = match results.next() {
                    Some(mlua::Value::Integer(n)) if n >= 0 => Some(n as usize),
                    Some(mlua::Value::Number(n)) if n >= 0.0 => Some(n as usize),
                    _ => None,
                };
                Err(LanguageError {
                    message,
                    byte_offset: offset,
                })
            }
            Some(other) => Err(LanguageError::new(format!(
                "the script's parse returned a {} rather than a table",
                other.type_name()
            ))),
        }
    }

    fn print(
        &self,
        dialect: &str,
        table: &NodeTable,
        options: &PrintOptions,
    ) -> Result<Vec<u8>, LanguageError> {
        let lua = self.lock();
        let print = self.function(&lua, "print")?;
        let t = convert::value_to_lua(&lua, &table_to_value(table))?;
        let index: Function = lua
            .globals()
            .get::<Table>("fig")
            .and_then(|fig| fig.get("index"))
            .map_err(|e| LanguageError::new(e.to_string()))?;
        let t: Table = index.call(t).map_err(lua_error)?;
        let opts = lua
            .create_table()
            .map_err(|e| LanguageError::new(e.to_string()))?;
        let set = |k: &str, v: mlua::Value| {
            opts.set(k, v)
                .map_err(|e| LanguageError::new(e.to_string()))
        };
        set("pretty", mlua::Value::Boolean(options.pretty))?;
        set(
            "strip_comments",
            mlua::Value::Boolean(options.strip_comments),
        )?;
        set("indent", mlua::Value::Integer(options.indent as i64))?;
        set("width", mlua::Value::Integer(options.width as i64))?;
        let out: mlua::LuaString = print.call((dialect, t, opts)).map_err(lua_error)?;
        Ok(out.as_bytes().to_vec())
    }

    fn render(&self, which: Renderer, args: RenderArgs<'_>) -> Result<Vec<u8>, LanguageError> {
        let lua = self.lock();
        let render = self.function(&lua, "render")?;
        let a = lua
            .create_table()
            .map_err(|e| LanguageError::new(e.to_string()))?;
        let set = |k: &str, v: &[u8]| -> Result<(), LanguageError> {
            let s = lua
                .create_string(v)
                .map_err(|e| LanguageError::new(e.to_string()))?;
            a.set(k, s).map_err(|e| LanguageError::new(e.to_string()))
        };
        set("dialect", args.dialect.as_bytes())?;
        set("indent", args.indent)?;
        set("key", args.key)?;
        set("value", args.value)?;
        set("old_key", args.old_key)?;
        // What fig's bare-literal rules made of the value, for the value
        // renderer: "null", "bool", "int", "float", "datetime" or "string".
        set("literal", args.literal.name().as_bytes())?;
        let name = match which {
            Renderer::Value => "value",
            Renderer::Entry => "entry",
            Renderer::Item => "item",
            Renderer::Tail => "tail",
            Renderer::Key => "key",
        };
        let out: mlua::LuaString = render.call((name, a)).map_err(lua_error)?;
        Ok(out.as_bytes().to_vec())
    }
}

/// Convenience: [`fig::language::register`] over a script file.
pub fn register_file(
    path: impl AsRef<Path>,
) -> Result<Vec<fig::Format>, Box<dyn std::error::Error>> {
    let lang = LuaLanguage::from_file(path)?;
    Ok(fig::language::register(lang)?)
}

/// The `Value` a Lua value converts to, for tests and tools.
pub fn to_value(v: &mlua::Value) -> Result<Value, LanguageError> {
    convert::lua_to_value(v)
}
