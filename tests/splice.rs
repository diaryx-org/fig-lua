//! Splice text: what a script's `print` writes when fig asks for a value as
//! the editor splices it into a document (`options.splice`), and not as a
//! document of its own. The bindings' editors ask for it for every value
//! they hand the editor; `Document::serialize` and `Value::serialize` never
//! do. Two twins answer it, as their compiled siblings' `printSplice` does:
//! plist writes the bare element, and NestedText a one-line scalar's text or
//! a nested block after a line break.

use std::path::Path;
use std::sync::OnceLock;

use fig::language::{Language, PrintOptions};
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

fn key(k: &str) -> Segment<'_> {
    Segment::Key(k)
}

fn map(entries: Vec<(&str, Value)>) -> Value {
    Value::Map(
        entries
            .into_iter()
            .map(|(k, v)| (Value::Str(k.to_owned()), v))
            .collect(),
    )
}

fn s(text: &str) -> Value {
    Value::Str(text.to_owned())
}

// ── the option reaches `print` ────────────────────────────────────────────

/// A dotenv whose `print` marks splice text, so an edit shows what it was
/// told: `B=Stwo` is a value printed with `splice = true`, and a whole
/// document printed with it would not reparse. The spy is loaded after
/// `dotenv.lua`, in one chunk, as its local `dotenv`.
fn spy() -> Format {
    static FORMAT: OnceLock<Format> = OnceLock::new();
    *FORMAT.get_or_init(|| {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let read = |path: &str| std::fs::read_to_string(root.join(path)).expect("reads");
        let source = format!(
            "local dotenv = (function()\n{}\nend)()\n{}",
            read("languages/dotenv.lua"),
            read("tests/modules/splice-spy.lua")
        );
        let lang = LuaLanguage::from_source("splice-spy", &source).expect("the spy loads");
        fig::language::register(lang).expect("registers")[0]
    })
}

#[test]
fn print_is_told_splice_for_an_editor_value_and_not_for_a_document() {
    let mut ed = Editor::open(b"A=1\n", spy()).unwrap();
    ed.insert_value(&[], "B", "two").unwrap();
    assert_eq!(ed.source().unwrap(), "A=1\nB=Stwo\n");
    ed.replace_value(&[key("A")], "3").unwrap();
    assert_eq!(ed.source().unwrap(), "A=S3\nB=Stwo\n");

    let doc = Document::parse(b"C=3\n", spy()).unwrap();
    assert_eq!(doc.serialize(spy()).unwrap(), "C=3\n");
    assert_eq!(map(vec![("D", s("4"))]).serialize(spy()).unwrap(), "D=4\n");
}

#[test]
fn the_bridge_carries_splice_both_ways() {
    // Straight through `Language::print`, without the editor: the option
    // is in the table the script's `print` is handed.
    let lang = script("nestedtext.lua");
    let table = lang.parse("lua-nestedtext", b"> two\n> lines\n").unwrap();
    let print = |splice: bool| {
        let mut options = PrintOptions::default();
        options.splice = splice;
        String::from_utf8(lang.print("lua-nestedtext", &table, &options).unwrap()).unwrap()
    };
    assert_eq!(print(false), "> two\n> lines\n");
    assert_eq!(print(true), "\n> two\n> lines\n");
}

// ── plist ─────────────────────────────────────────────────────────────────

fn lua_plist() -> Format {
    static FORMAT: OnceLock<Format> = OnceLock::new();
    *FORMAT.get_or_init(|| fig::language::register(script("plist.lua")).expect("registers")[0])
}

#[test]
fn plist_splices_a_scalar_as_its_bare_element_and_renames_a_key_inside_its_element() {
    // The compiled plist's own binding test (fig's
    // `editor_plist_keys_are_names_on_insert_and_replace`), byte for byte.
    let src = b"<dict>\n  <key>a</key>\n  <string>x</string>\n</dict>\n";
    let mut ed = Editor::open(src, lua_plist()).unwrap();
    ed.insert_value(&[], "n", 42i64).unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "<dict>\n  <key>a</key>\n  <string>x</string>\n  <key>n</key>\n  <integer>42</integer>\n</dict>\n"
    );
    ed.rename_key(&[key("a")], "b&c").unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "<dict>\n  <key>b&amp;c</key>\n  <string>x</string>\n  <key>n</key>\n  <integer>42</integer>\n</dict>\n"
    );
    ed.replace_value(&[key("n")], 2.5f64).unwrap();
    assert!(ed.source().unwrap().contains("<real>2.5</real>"));
}

#[test]
fn plist_splices_a_container_as_the_compiled_format_does() {
    // What the compiled plist writes for the same values (`fig patch`
    // into `-i plist`, which asks for splice text as the bindings do):
    // the element's lines at the top level, moved under the entry.
    let src = b"<dict>\n  <key>a</key>\n  <string>x</string>\n  <key>o</key>\n  <dict>\n    <key>n</key>\n    <integer>1</integer>\n  </dict>\n</dict>\n";
    let mut ed = Editor::open(src, lua_plist()).unwrap();
    ed.replace_value(&[key("a")], "y").unwrap();
    ed.replace_value(&[key("o"), key("n")], 2i64).unwrap();
    ed.insert_value(&[key("o")], "k", "v").unwrap();
    ed.insert_value(&[], "n", 42i64).unwrap();
    ed.insert_value(&[], "r", 2.5f64).unwrap();
    ed.insert_value(&[], "t", true).unwrap();
    let m = map(vec![
        ("q", Value::Seq(vec![Value::Int(1), s("two")])),
        ("e", Value::Map(vec![])),
    ]);
    ed.insert_value(&[], "m", m).unwrap();
    ed.insert_value(&[], "l", Value::Seq(vec![])).unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "<dict>\n  <key>a</key>\n  <string>y</string>\n  <key>o</key>\n  <dict>\n    <key>n</key>\n    <integer>2</integer>\n    <key>k</key>\n    <string>v</string>\n  </dict>\n  <key>n</key>\n  <integer>42</integer>\n  <key>r</key>\n  <real>2.5</real>\n  <key>t</key>\n  <true/>\n  <key>m</key>\n  <dict>\n    <key>q</key>\n    <array>\n      <integer>1</integer>\n      <string>two</string>\n    </array>\n    <key>e</key>\n    <dict/>\n  </dict>\n  <key>l</key>\n  <array/>\n</dict>\n"
    );

    // Under a tab-indented entry, as the compiled format writes it: the
    // entry's own indent, then the printer's two-space steps.
    let src = b"<dict>\n\t<key>o</key>\n\t<dict>\n\t\t<key>n</key>\n\t\t<integer>1</integer>\n\t</dict>\n</dict>\n";
    let mut ed = Editor::open(src, lua_plist()).unwrap();
    let m = map(vec![("x", Value::Seq(vec![Value::Int(1)]))]);
    ed.insert_value(&[key("o")], "m", m).unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "<dict>\n\t<key>o</key>\n\t<dict>\n\t\t<key>n</key>\n\t\t<integer>1</integer>\n\t\t<key>m</key>\n\t\t<dict>\n\t\t  <key>x</key>\n\t\t  <array>\n\t\t    <integer>1</integer>\n\t\t  </array>\n\t\t</dict>\n\t</dict>\n</dict>\n"
    );
}

#[test]
fn plist_replaces_a_scalar_with_a_container_as_the_compiled_format_does() {
    // The compiled format's bytes (`fig patch` into `-i plist`): a value
    // replaced in place is spliced as it stands, not re-indented — the
    // engine's, for both.
    let src = b"<dict>\n  <key>a</key>\n  <string>x</string>\n</dict>\n";
    let mut ed = Editor::open(src, lua_plist()).unwrap();
    ed.replace_value(&[key("a")], map(vec![("z", Value::Int(1))]))
        .unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "<dict>\n  <key>a</key>\n  <dict>\n  <key>z</key>\n  <integer>1</integer>\n</dict>\n</dict>\n"
    );
}

#[test]
fn plist_splice_text_is_the_bare_element_and_a_document_keeps_its_wrapper() {
    let lang = script("plist.lua");
    let table = lang
        .parse(
            "lua-plist",
            b"<dict><key>q</key><array><integer>1</integer></array></dict>",
        )
        .unwrap();
    let mut options = PrintOptions::default();
    options.splice = true;
    // The compiled printer's `printSplice` test, byte for byte.
    assert_eq!(
        String::from_utf8(lang.print("lua-plist", &table, &options).unwrap()).unwrap(),
        "<dict>\n  <key>q</key>\n  <array>\n    <integer>1</integer>\n  </array>\n</dict>"
    );
    let whole = String::from_utf8(
        lang.print("lua-plist", &table, &PrintOptions::default())
            .unwrap(),
    )
    .unwrap();
    assert!(whole.starts_with("<?xml"), "{whole}");
    assert!(whole.contains("<plist version=\"1.0\">"), "{whole}");
}

// ── NestedText ────────────────────────────────────────────────────────────

fn lua_nestedtext() -> Format {
    static FORMAT: OnceLock<Format> = OnceLock::new();
    *FORMAT.get_or_init(|| fig::language::register(script("nestedtext.lua")).expect("registers")[0])
}

/// The same edits through the twin and through the compiled format, which
/// is in fig's default set: the sources must agree after every one.
fn both(src: &str, edit: impl Fn(&mut Editor)) -> String {
    let mut mine = Editor::open(src.as_bytes(), lua_nestedtext()).unwrap();
    let mut theirs = Editor::open(src.as_bytes(), fig_nestedtext::format().unwrap()).unwrap();
    edit(&mut mine);
    edit(&mut theirs);
    let (mine, theirs) = (mine.source().unwrap(), theirs.source().unwrap());
    assert_eq!(
        mine, theirs,
        "the twin's edit differs from the compiled one"
    );
    mine.to_owned()
}

#[test]
fn nestedtext_splices_a_scalar_once_and_a_container_as_a_nested_block() {
    // A one-line scalar rides the key's line, blocked nowhere.
    let out = both("name: fig\n", |ed| {
        ed.replace_value(&[key("name")], "h2").unwrap();
    });
    assert_eq!(out, "name: h2\n");
    // A string with a line break is a `>` block under the key, once.
    let out = both("name: fig\n", |ed| {
        ed.insert_value(&[], "new", "two\nlines").unwrap();
    });
    assert_eq!(out, "name: fig\nnew:\n    > two\n    > lines\n");
    // A mapping and a list land as nested entries and items (fig's
    // `editor_nestedtext_takes_a_container_as_nested_entries`).
    let m = map(vec![("x", s("1")), ("l", Value::Seq(vec![s("a"), s("b")]))]);
    let out = both("name: fig\n", |ed| {
        ed.insert_value(&[], "m", m.clone()).unwrap();
    });
    assert_eq!(
        out,
        "name: fig\nm:\n    x: 1\n    l:\n        - a\n        - b\n"
    );
    // A container over a scalar, a list item holding a mapping, and a
    // scalar back over the container.
    let out = both("k: v\nm: 1\nl:\n    - a\n", |ed| {
        ed.replace_value(&[key("m")], map(vec![("x", s("1"))]))
            .unwrap();
        ed.append_value(&[key("l")], map(vec![("y", s("2"))]))
            .unwrap();
    });
    assert_eq!(
        out,
        "k: v\nm:\n    x: 1\nl:\n    - a\n    -\n        y: 2\n"
    );
    let out = both("m:\n    x: 1\n", |ed| {
        ed.replace_value(&[key("m")], "flat").unwrap();
    });
    assert_eq!(out, "m: flat\n");
}

#[test]
fn nestedtext_splices_an_empty_container_as_its_inline_form() {
    let out = both("k: v\n", |ed| {
        ed.insert_value(&[], "e", Value::Map(vec![])).unwrap();
        ed.insert_value(&[], "l", Value::Seq(vec![])).unwrap();
    });
    assert_eq!(out, "k: v\ne:\n    {}\nl:\n    []\n");
    let doc = Document::parse(out.as_bytes(), lua_nestedtext()).unwrap();
    assert_eq!(
        doc.to_value().unwrap(),
        map(vec![
            ("k", s("v")),
            ("e", Value::Map(vec![])),
            ("l", Value::Seq(vec![]))
        ])
    );
}

#[test]
fn nestedtext_prints_an_empty_container_as_the_compiled_printer_does() {
    for v in [
        map(vec![("a", Value::Map(vec![])), ("b", Value::Seq(vec![]))]),
        map(vec![("c", Value::Seq(vec![Value::Seq(vec![])]))]),
        Value::Map(vec![]),
        Value::Seq(vec![]),
    ] {
        let mine = v.serialize(lua_nestedtext()).unwrap();
        assert_eq!(
            mine,
            v.serialize(fig_nestedtext::format().unwrap()).unwrap()
        );
        assert_eq!(
            Document::parse(mine.as_bytes(), lua_nestedtext())
                .unwrap()
                .to_value()
                .unwrap(),
            v,
            "{mine}"
        );
    }
    assert_eq!(
        map(vec![("a", Value::Map(vec![]))])
            .serialize(lua_nestedtext())
            .unwrap(),
        "a:\n    {}\n"
    );
    assert_eq!(
        Value::Map(vec![]).serialize(lua_nestedtext()).unwrap(),
        "{}\n"
    );
    // A value serialized to be written out is still a document: a scalar
    // root is a `>` block.
    assert_eq!(s("h2").serialize(lua_nestedtext()).unwrap(), "> h2\n");
}

#[test]
fn nestedtext_renders_text_that_opens_with_a_break_and_reads_as_nestedtext_as_nested() {
    // The CLI hands the renderers bare text; the compiled `nestedBlock` is
    // the rule (its `editor_helper.zig` test's cases, as the renderers see
    // them): a line break and then lines that read as NestedText on their
    // own are re-indented under the key; anything else is a string.
    use fig::language::{Literal, RenderArgs, Renderer};
    let lang = script("nestedtext.lua");
    let render = |which, indent: &str, key: &str, value: &str| {
        String::from_utf8(
            lang.render(
                which,
                RenderArgs::default()
                    .dialect("lua-nestedtext")
                    .indent(indent.as_bytes())
                    .key(key.as_bytes())
                    .value(value.as_bytes())
                    .literal(Literal::String)
                    .old_key(b""),
            )
            .unwrap(),
        )
        .unwrap()
    };
    assert_eq!(
        render(Renderer::Entry, "", "m", "\nx: 1\ny:\n    - a"),
        "m:\n    x: 1\n    y:\n        - a"
    );
    assert_eq!(
        render(Renderer::Entry, "    ", "m", "\n- a\n- b\n"),
        "m:\n        - a\n        - b"
    );
    assert_eq!(render(Renderer::Item, "", "", "\n{}"), "-\n    {}");
    assert_eq!(render(Renderer::Tail, "", "m", "\nx: 1"), ":\n    x: 1");
    // A `>` block is NestedText too: splice text for a multi-line string.
    assert_eq!(
        render(Renderer::Tail, "", "m", "\n> two\n> lines\n"),
        ":\n    > two\n    > lines"
    );
    // A blank line inside the block takes no indent.
    assert_eq!(
        render(Renderer::Entry, "", "m", "\nx:\n\n    - a"),
        "m:\n    x:\n\n        - a"
    );
    // Not NestedText on its own, or no leading break: a string.
    assert_eq!(
        render(Renderer::Tail, "", "m", "x: 1\ny: 2"),
        ":\n    > x: 1\n    > y: 2"
    );
    assert_eq!(
        render(Renderer::Tail, "", "m", "\nhello"),
        ":\n    >\n    > hello"
    );
    assert_eq!(render(Renderer::Tail, "", "m", "\n"), ":\n    >\n    >");
}

#[test]
fn nestedtext_root_tail_takes_a_nested_block_as_it_stands() {
    use fig::language::{Literal, RenderArgs, Renderer};
    let lang = script("nestedtext.lua");
    let tail = |value: &str| {
        String::from_utf8(
            lang.render(
                Renderer::Tail,
                RenderArgs::default()
                    .dialect("lua-nestedtext")
                    .value(value.as_bytes())
                    .literal(Literal::String),
            )
            .unwrap(),
        )
        .unwrap()
    };
    assert_eq!(tail("\nx: 1\n- no"), ">\n> x: 1\n> - no");
    assert_eq!(tail("\nx: 1\ny:\n    - a\n"), "x: 1\ny:\n    - a");
    assert_eq!(tail("\n- a"), "- a");
    assert_eq!(tail("hi\n\nthere"), "> hi\n>\n> there");
}
