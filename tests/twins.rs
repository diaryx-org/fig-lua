//! Each script in `languages/` is a twin of a format fig compiles in, and
//! is held to it two ways.
//!
//! **Table for table.** `tests/fixtures/<format>/*.<ext>` are documents;
//! beside each, `*.table.json` is the node table the compiled format gives
//! for it, printed by `fig lang table -i <format>` — regenerate one with
//! that command when the compiled format changes. The script's `parse` must
//! give the same table: every row, span, text and comment.
//!
//! **Through fig.** The script is registered in-process, the same source is
//! parsed through it and through the compiled format, and the two trees
//! are printed through the compiled printer, edited the same way, and
//! compared. What `fig lang check lua-dotenv --against dotenv` does from
//! the command line, without the command line.

use std::path::Path;
use std::sync::OnceLock;

use fig::language::{Language, Literal, RenderArgs, Renderer};
use fig::{Document, Editor, Format, Segment, Value};
use fig_lua::LuaLanguage;

fn script(name: &str) -> LuaLanguage {
    LuaLanguage::from_file(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("languages")
            .join(name),
    )
    .expect("the script loads")
}

/// A value with every map's keys sorted and every null entry dropped, so
/// two JSON spellings of one table compare equal whichever side wrote them.
fn canonical(v: &Value) -> Value {
    match v {
        Value::Map(entries) => {
            let mut out: Vec<(Value, Value)> = entries
                .iter()
                .filter(|(_, v)| !matches!(v, Value::Null))
                .map(|(k, v)| (canonical(k), canonical(v)))
                .collect();
            out.sort_by(|a, b| format!("{:?}", a.0).cmp(&format!("{:?}", b.0)));
            Value::Map(out)
        }
        Value::Seq(items) => Value::Seq(items.iter().map(canonical).collect()),
        // A span is written as an unsigned integer by one side and read
        // back as a signed one by the other.
        Value::Uint(n) => match i64::try_from(*n) {
            Ok(i) => Value::Int(i),
            Err(_) => Value::Uint(*n),
        },
        other => other.clone(),
    }
}

fn fixtures(format: &str, ext: &str) -> Vec<(String, Vec<u8>, Value)> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(format);
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&dir).expect("fixture directory") {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some(ext) {
            continue;
        }
        let source = std::fs::read(&path).unwrap();
        let table_path = path.with_extension("table.json");
        let table_json = std::fs::read(&table_path)
            .unwrap_or_else(|_| panic!("{} has no table beside it", path.display()));
        let table = Document::parse(&table_json, Format::Json)
            .expect("the table is JSON")
            .to_value()
            .unwrap();
        out.push((
            path.file_name().unwrap().to_string_lossy().into_owned(),
            source,
            table,
        ));
    }
    assert!(!out.is_empty(), "no fixtures under {}", dir.display());
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// One registration per process: a name can be registered once.
fn lua_dotenv() -> Format {
    static FORMAT: OnceLock<Format> = OnceLock::new();
    *FORMAT.get_or_init(|| fig::language::register(script("dotenv.lua")).expect("registers")[0])
}

#[test]
fn dotenv_parses_every_fixture_to_the_compiled_table() {
    let lang = script("dotenv.lua");
    for (name, source, want) in fixtures("dotenv", "env") {
        let table = lang
            .parse("lua-dotenv", &source)
            .unwrap_or_else(|e| panic!("{name}: {}", e.message));
        let got = fig::helper::table_to_value(&table);
        assert_eq!(
            canonical(&got),
            canonical(&want),
            "{name}: the script's table differs from the compiled one\n  got:  {}\n  want: {}",
            fig::helper::encode(&canonical(&got)),
            fig::helper::encode(&canonical(&want)),
        );
    }
}

#[test]
fn dotenv_registers_and_is_the_compiled_format_at_every_entry_point() {
    let lua = lua_dotenv();
    assert!(matches!(lua, Format::Runtime(_)));
    assert_eq!(Format::by_name("lua-dotenv"), Some(lua));

    for (name, source, _) in fixtures("dotenv", "env") {
        let mine = Document::parse(&source, lua).unwrap_or_else(|e| panic!("{name}: {e}"));
        let theirs = Document::parse(&source, Format::Dotenv).unwrap();
        // The same tree, comments included: both print the same through
        // the compiled printer and through the script's.
        assert_eq!(
            mine.serialize(Format::Dotenv).unwrap(),
            theirs.serialize(Format::Dotenv).unwrap(),
            "{name}: trees differ"
        );
        assert_eq!(
            mine.serialize(lua).unwrap(),
            theirs.serialize(lua).unwrap(),
            "{name}: the script prints the two trees differently"
        );
        assert_eq!(
            mine.serialize(lua).unwrap(),
            theirs.serialize(Format::Dotenv).unwrap(),
            "{name}: the script's printer differs from the compiled one"
        );
        assert_eq!(mine.to_value().unwrap(), theirs.to_value().unwrap());
    }
}

#[test]
fn dotenv_refuses_what_the_compiled_format_refuses_with_its_words_and_offset() {
    // The compiled parser's messages, and the offsets the `fig` CLI reports
    // for it (`fig get bad.env -i dotenv`), which the C API does not yet
    // carry for a compiled format — so the twin is held to the CLI's
    // numbers here, and to the compiled format's refusal.
    let lua = lua_dotenv();
    for (bad, message, offset) in [
        (
            &b"A=1\nB\nC=2\n"[..],
            "expected `=` after this key; every dotenv line is `KEY=value`",
            5,
        ),
        (
            b"A=1\n-B=2\n",
            "not a valid key here; a dotenv key is a bash identifier (`[A-Za-z_][A-Za-z0-9_]*`)",
            4,
        ),
        (
            b"A=\"unclosed\n",
            "unclosed quoted value; expected a matching `\"`/`'` before the end of the file",
            12,
        ),
        (
            b"A=\"bad \\q escape\"\n",
            "invalid escape in a double-quoted value; supported: \\n \\t \\r \\\\ \\\" — use a single-quoted value for raw text with backslashes",
            17,
        ),
        (
            b"A=\"x\" y\n",
            "unexpected content after this quoted value; only a `#` comment may follow it on the same line",
            6,
        ),
        (
            b"A=1\rB=2\n",
            "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`",
            3,
        ),
        (
            b"\n=1\n",
            "unexpected content here; expected `KEY=value` (optionally `export KEY=value`)",
            1,
        ),
    ] {
        assert!(Document::parse(bad, Format::Dotenv).is_err());
        match Document::parse(bad, lua) {
            Err(fig::Error::Parse(e)) => {
                assert_eq!(e.message, message, "{}", String::from_utf8_lossy(bad));
                // Never 0 here: `FigError.byte_offset` 0 is "unknown" at the
                // C ABI, so the one offset the binding cannot carry is the
                // first byte.
                assert_eq!(
                    e.byte_offset,
                    Some(offset),
                    "{}",
                    String::from_utf8_lossy(bad)
                );
            }
            other => panic!("expected a parse error, got {other:?}"),
        }
    }
}

#[test]
fn dotenv_edits_as_the_compiled_format_does() {
    let lua = lua_dotenv();
    let src = b"# secrets\nexport DB_URL=postgres://localhost/app # local\nAPI_KEY=\"abc\\n123\"\nEMPTY=\n";
    let mut mine = Editor::open(src, lua).unwrap();
    let mut theirs = Editor::open(src, Format::Dotenv).unwrap();
    for ed in [&mut mine, &mut theirs] {
        ed.replace_value(&[Segment::Key("DB_URL")], "sqlite://x")
            .unwrap();
        ed.insert_value(&[], "NEW", "two words").unwrap();
        ed.delete(&[Segment::Key("EMPTY")]).unwrap();
        ed.add_leading_comment(&[Segment::Key("API_KEY")], "the key")
            .unwrap();
    }
    assert_eq!(mine.source().unwrap(), theirs.source().unwrap());
    assert!(mine.source().unwrap().contains("# the key\nAPI_KEY="));
}

#[test]
fn plist_parses_every_fixture_to_the_compiled_table() {
    let lang = script("plist.lua");
    for (name, source, want) in fixtures("plist", "plist") {
        let table = lang
            .parse("lua-plist", &source)
            .unwrap_or_else(|e| panic!("{name}: {}", e.message));
        let got = fig::helper::table_to_value(&table);
        assert_eq!(
            canonical(&got),
            canonical(&want),
            "{name}: the script's table differs from the compiled one"
        );
    }
}

#[test]
fn plist_registers_and_renders_typed_values() {
    // plist is not in fig's default feature set, so the compiled sibling is
    // not here to compare against in-process; `fig lang check lua-plist
    // --against plist` is that comparison, and the CLI is where the editor
    // is driven with bare text (the Rust editor spells a key through the
    // printer, which for plist is not the key — a task in fig). What is
    // checked here is the harness, the printer, and the two renderers by
    // the rules the compiled ones follow.
    let lang = script("plist.lua");
    // The value renderer spells the kind fig's bare-literal rules gave the
    // text — `literal` — and decides none itself.
    let render = |which: Renderer, key: &str, value: &str, literal: Literal| -> String {
        let args = RenderArgs {
            dialect: "lua-plist",
            indent: b"  ",
            key: key.as_bytes(),
            value: value.as_bytes(),
            literal,
            old_key: b"",
        };
        String::from_utf8(lang.render(which, args).expect("renders")).unwrap()
    };
    for (bare, literal, element) in [
        ("42", Literal::Int, "<integer>42</integer>"),
        ("-1_000", Literal::Int, "<integer>-1_000</integer>"),
        ("007", Literal::String, "<string>007</string>"),
        ("2.5", Literal::Float, "<real>2.5</real>"),
        ("true", Literal::Bool, "<true/>"),
        ("false", Literal::Bool, "<false/>"),
        ("Yes", Literal::String, "<string>Yes</string>"),
        ("2026-09-10", Literal::Datetime, "<date>2026-09-10</date>"),
        (
            "1 < 2 & 3",
            Literal::String,
            "<string>1 &lt; 2 &amp; 3</string>",
        ),
        ("<data>aGk=</data>", Literal::String, "<data>aGk=</data>"),
        (
            "  <string>2.0</string>  ",
            Literal::String,
            "<string>2.0</string>",
        ),
    ] {
        assert_eq!(
            render(Renderer::Value, "", bare, literal),
            element,
            "{bare}"
        );
    }
    assert!(
        lang.render(
            Renderer::Value,
            RenderArgs {
                value: b"null",
                literal: Literal::Null,
                ..Default::default()
            }
        )
        .is_err()
    );
    assert_eq!(
        render(Renderer::Entry, "a&b", "<true/>", Literal::String),
        "<key>a&amp;b</key>\n  <true/>"
    );

    let lua = fig::language::register(lang).expect("registers")[0];
    let src = b"<dict>\n  <key>a</key>\n  <string>x</string>\n  <key>l</key>\n  <array><integer>1</integer></array>\n</dict>\n";
    let doc = Document::parse(src, lua).unwrap();
    assert_eq!(
        doc.to_value().unwrap().get("a").and_then(Value::as_str),
        Some("x")
    );
    let printed = doc.serialize(lua).unwrap();
    assert_eq!(
        printed,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>a</key>\n  <string>x</string>\n  <key>l</key>\n  <array>\n    <integer>1</integer>\n  </array>\n</dict>\n</plist>\n"
    );
    // The literal's arrival through the engine is proved at the command
    // line (`fig set … --lang lua-plist` against `-i plist`), where the
    // value is bare text: the Rust editor prints a value through the format
    // before the renderer sees it, so in-process a `42` is already an
    // element by the time `literal` is computed.
    // Deleting is generic and line-based, so it holds without a renderer.
    let mut ed = Editor::open(src, lua).unwrap();
    ed.delete(&[Segment::Key("a")]).unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "<dict>\n  <key>l</key>\n  <array><integer>1</integer></array>\n</dict>\n"
    );
}

#[test]
fn canonical_parses_every_fixture_to_the_compiled_table() {
    let lang = script("canonical.lua");
    for (name, source, want) in fixtures("canonical", "canonical") {
        let table = lang
            .parse("lua-canonical", &source)
            .unwrap_or_else(|e| panic!("{name}: {}", e.message));
        let got = fig::helper::table_to_value(&table);
        assert_eq!(
            canonical(&got),
            canonical(&want),
            "{name}: the script's table differs from the compiled one\n  got:  {}\n  want: {}",
            fig::helper::encode(&canonical(&got)),
            fig::helper::encode(&canonical(&want)),
        );
    }
}

#[test]
fn canonical_prints_one_spelling_that_reparses_to_the_same_table() {
    // The canonical form is opt-in in fig's build, so the compiled sibling
    // is not here to compare against in-process; `fig lang check
    // lua-canonical --against canonical` is that comparison. What is
    // checked here is the printer: every fixture prints to a document
    // that parses back to the same rows and comments, and a second print
    // is the first.
    let lang = script("canonical.lua");
    for (name, source, _) in fixtures("canonical", "canonical") {
        let table = lang.parse("lua-canonical", &source).unwrap();
        let printed = lang
            .print("lua-canonical", &table, &Default::default())
            .unwrap_or_else(|e| panic!("{name}: {}", e.message));
        let again = lang.parse("lua-canonical", &printed).unwrap_or_else(|e| {
            panic!(
                "{name}: {}\n{}",
                e.message,
                String::from_utf8_lossy(&printed)
            )
        });
        // Spans move; rows, texts and comments do not.
        let strip = |t: &fig::language::NodeTable| {
            let mut v = fig::helper::table_to_value(t);
            let rows = match &mut v {
                Value::Map(entries) => entries
                    .iter_mut()
                    .find(|(k, _)| k.as_str() == Some("rows"))
                    .map(|(_, rows)| rows),
                _ => None,
            };
            if let Some(Value::Seq(rows)) = rows {
                for row in rows.iter_mut() {
                    if let Value::Map(fields) = row {
                        fields.retain(|(k, _)| k.as_str() != Some("span"));
                    }
                }
            }
            canonical(&v)
        };
        assert_eq!(
            strip(&table),
            strip(&again),
            "{name}: the print does not reparse to the same tree"
        );
        let twice = lang
            .print("lua-canonical", &again, &Default::default())
            .unwrap();
        assert_eq!(
            printed, twice,
            "{name}: the second print differs from the first"
        );
    }

    // The layout is the compiled printer's, with a trailing comment kept
    // on the line of the value it belongs to.
    let table = lang
        .parse(
            "lua-canonical",
            b"/* d */ { \"a\": [1, ~f2, @local_date \"2024-01-01\"], &x \"b\": {}, // e\n \"c\": *x }\n",
        )
        .unwrap();
    let printed = lang
        .print("lua-canonical", &table, &Default::default())
        .unwrap();
    assert_eq!(
        String::from_utf8(printed).unwrap(),
        "{\n  /* d */\n  \"a\": [\n    1,\n    ~f2,\n    @local_date \"2024-01-01\"\n  ],\n  &x \"b\": {}, // e\n  \"c\": *x\n}\n"
    );
}

#[test]
fn a_script_that_is_not_a_description_is_refused_at_load() {
    let err = LuaLanguage::from_source("bad.lua", "return 42").unwrap_err();
    assert!(err.to_string().contains("bad.lua"), "{err}");
    let err = LuaLanguage::from_source("syntax.lua", "return {").unwrap_err();
    assert!(err.to_string().contains("syntax.lua"), "{err}");
}

#[test]
fn a_parse_that_raises_is_a_language_error() {
    let lang = LuaLanguage::from_source(
        "raise.lua",
        r#"
        local M = { name = "raise", caps = { read = true }, dialects = { { name = "raise" } }, samples = { "" } }
        function M.parse(_, input)
          if input == "" then
            local t = fig.table(); t:row("null", nil, {0, 0}); return t
          end
          error("no thanks")
        end
        return M
        "#,
    )
    .unwrap();
    let err = lang.parse("raise", b"x").unwrap_err();
    assert_eq!(err.message, "no thanks");
    assert_eq!(err.byte_offset, None);
    let err = LuaLanguage::from_source(
        "refuse.lua",
        r#"
        local M = { name = "refuse", caps = { read = true }, dialects = { { name = "refuse" } }, samples = { "" } }
        function M.parse(_, input) return fig.fail("not here", 3) end
        return M
        "#,
    )
    .unwrap()
    .parse("refuse", b"x")
    .unwrap_err();
    assert_eq!(
        (err.message.as_str(), err.byte_offset),
        ("not here", Some(3))
    );
}
