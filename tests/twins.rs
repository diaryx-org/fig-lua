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

use fig::language::Language;
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
