//! The grammar, through the README's own example: the first `lua` block
//! in `README.md` is loaded as a script, so the example cannot drift from
//! what `fig.grammar` does.

use fig::language::Language;
use fig::{Document, Editor, Segment, Value};
use fig_lua::LuaLanguage;

fn readme_script() -> String {
    let readme =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/README.md")).unwrap();
    let start = readme.find("```lua\n").expect("a lua block") + "```lua\n".len();
    let end = readme[start..].find("\n```").expect("the block closes") + start;
    readme[start..end].to_owned()
}

fn tinykv() -> LuaLanguage {
    LuaLanguage::from_source("README.md", &readme_script()).expect("the README's script loads")
}

#[test]
fn the_readme_example_parses_its_sample_with_comments_bound() {
    let lang = tinykv();
    let table = lang
        .parse("tinykv", b"a=1\n# two\nb=two # words\n")
        .unwrap();
    let json = fig::helper::encode(&fig::helper::table_to_value(&table));
    assert_eq!(
        json,
        r#"{"rows":[{"kind":"mapping","parent":null,"span":[0,24]},{"kind":"keyvalue","parent":0,"span":[0,3]},{"kind":"string","parent":1,"span":[0,1],"text":"a"},{"kind":"string","parent":1,"span":[2,3],"text":"1"},{"kind":"keyvalue","parent":0,"span":[10,15]},{"kind":"string","parent":4,"span":[10,11],"text":"b"},{"kind":"string","parent":4,"span":[12,15],"text":"two"}],"regions":[],"mentions":[],"comments":[{"node":5,"slot":"leading","style":"line","text":"two"},{"node":6,"slot":"trailing","style":"line","text":"words"}]}"#
    );
}

#[test]
fn the_readme_example_applies_the_duplicate_policy_and_dangles_a_last_comment() {
    let lang = tinykv();
    let table = lang.parse("tinykv", b"a=1\na=2\n# end\n").unwrap();
    let v = fig::helper::table_to_value(&table);
    let rows = v.get("rows").and_then(Value::as_seq).unwrap();
    assert_eq!(rows.len(), 4, "one entry: the first keeps its place");
    assert_eq!(rows[3].get("text").and_then(Value::as_str), Some("2"));
    assert_eq!(
        rows[1].get("span").map(fig::helper::encode).as_deref(),
        Some("[0,3]")
    );
    let comments = v.get("comments").and_then(Value::as_seq).unwrap();
    assert_eq!(comments.len(), 1);
    assert_eq!(comments[0].get("node").and_then(Value::as_i64), Some(0));
    assert_eq!(
        comments[0].get("slot").and_then(Value::as_str),
        Some("dangling")
    );
}

#[test]
fn a_failure_raised_inside_the_grammar_is_reported_at_its_offset() {
    let lang = tinykv();
    let err = lang.parse("tinykv", b"a=1\nb\n").unwrap_err();
    assert_eq!(err.message, "expected `=` after this key");
    assert_eq!(err.byte_offset, Some(5));
    let err = lang.parse("tinykv", b"=1\n").unwrap_err();
    assert_eq!(err.message, "expected `key=value` here");
    assert_eq!(err.byte_offset, Some(0));
}

#[test]
fn the_readme_example_registers_prints_and_edits() {
    let format = fig::language::register(tinykv()).expect("the harness passes")[0];
    let src = b"a=1\n# two\nb=two # words\n";
    let doc = Document::parse(src, format).unwrap();
    assert_eq!(doc.serialize(format).unwrap().as_bytes(), src);
    let mut ed = Editor::open(src, format).unwrap();
    ed.replace_value(&[Segment::Key("a")], "one").unwrap();
    ed.insert_value(&[], "c", "3").unwrap();
    assert_eq!(ed.source().unwrap(), "a=one\n# two\nb=two # words\nc=3\n");
}
