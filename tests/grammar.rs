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

/// A section format small enough to read whole: `[name]` opens a section
/// or re-enters one, `k=v` is an entry, `#` a comment, `>` in front of a
/// line its depth. Every region, mention and comment comes from
/// `G.sections`; only what a header means is the script's.
const TINYSECTIONS: &str = r##"
local G = require("fig.grammar")
local M = { name = "tinysections", caps = { read = true }, dialects = { { name = "tinysections", extensions = { "tsec" } } } }
function M.parse(_dialect, input)
  local S = G.sections(input)
  local root = fig.mapping({ 0, #input })
  local current = root
  local pos = 0
  while pos < #input do
    local nl = input:find("\n", pos + 1, true) or (#input + 1)
    local line = input:sub(pos + 1, nl - 1)
    local depth, body = #line:match("^>*"), line:gsub("^>+", "")
    local at = pos + depth
    if body:sub(1, 1) == "#" then
      S:comment(body:sub(2), depth)
    elseif body:sub(1, 1) == "[" then
      local name = body:sub(2, -2)
      local span = { at + 1, at + 1 + #name }
      local e = root.by_key[name]
      if e then
        S:reopen(e.value, span, "header")
        current = e.value
      else
        local key = fig.scalar("string", span, name)
        S:claim(key, "leading")
        current = S:open(root, fig.entry(key, fig.mapping(span)), "header")
      end
    elseif body ~= "" then
      local eq = body:find("=", 1, true)
      local key = fig.scalar("string", { at, at + eq - 1 }, body:sub(1, eq - 1))
      S:claim(key, "leading", depth)
      current:put(fig.entry(key, fig.scalar("string", { at + eq, at + #body }, body:sub(eq + 1))))
    end
    pos = nl
  end
  S:claim(current, "dangling")
  return root
end
return M
"##;

#[test]
fn sections_record_the_header_lines_the_names_and_the_waiting_comments() {
    let lang = LuaLanguage::from_source("tinysections.lua", TINYSECTIONS).unwrap();
    let table = lang
        .parse(
            "tinysections",
            b"# about a\n[a]\nx=1\n[b]\n[a]\ny=2\n# end\n",
        )
        .unwrap();
    let v = fig::helper::table_to_value(&table);
    let regions = fig::helper::encode(v.get("regions").unwrap());
    // `[a]` at 10, `[b]` at 18, `[a]` again at 22: each whole line, newline
    // included, on the section it opened or re-entered — `a` is node 3
    // (root, keyvalue, key, mapping), `b` node 12.
    assert_eq!(
        regions,
        r#"[{"node":3,"start":10,"end":14},{"node":3,"start":22,"end":26},{"node":12,"start":18,"end":22}]"#
    );
    let mentions = fig::helper::encode(v.get("mentions").unwrap());
    assert_eq!(
        mentions,
        r#"[{"node":3,"span":[11,12],"kind":"header"},{"node":3,"span":[23,24],"kind":"header"},{"node":12,"span":[19,20],"kind":"header"}]"#
    );
    let comments = fig::helper::encode(v.get("comments").unwrap());
    assert_eq!(
        comments,
        r#"[{"node":2,"slot":"leading","style":"line","text":" about a"},{"node":3,"slot":"dangling","style":"line","text":" end"}]"#
    );
}

#[test]
fn sections_take_the_waiting_comments_by_depth() {
    let lang = LuaLanguage::from_source("tinysections.lua", TINYSECTIONS).unwrap();
    // A key at depth 1 claims only the comments at its depth or deeper;
    // the shallower one keeps waiting, and dangles at the end.
    let table = lang
        .parse("tinysections", b"[s]\n#shallow\n>#deep\n>k=v\n")
        .unwrap();
    let v = fig::helper::table_to_value(&table);
    let comments = fig::helper::encode(v.get("comments").unwrap());
    assert_eq!(
        comments,
        r#"[{"node":3,"slot":"dangling","style":"line","text":"shallow"},{"node":5,"slot":"leading","style":"line","text":"deep"}]"#
    );
}
