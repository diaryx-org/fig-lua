//! `fig-lua <script.lua>`: serve the format a script defines to a `fig`
//! binary, as a helper process — what a `languages.figl` names as the
//! language's `command`:
//!
//! ```fig
//! language[]
//! > name = lua-dotenv
//! > extensions = [env]
//! > command = [fig-lua, ~/.config/fig/languages/dotenv.lua]
//! ```
//!
//! `fig-lua check <script.lua>` loads the script and registers it here, in
//! this process, which runs fig's own harness over the script's samples —
//! the same check the `fig` CLI makes when it loads a helper — and prints
//! what it declared or why it was refused.

use std::process::ExitCode;

use fig_lua::LuaLanguage;

fn usage() -> String {
    format!(
        "fig-lua {}\n\
         \n\
         Usage: fig-lua <script.lua>          serve the script's format on stdin/stdout\n\
         \x20      fig-lua check <script.lua>    load it, run fig's harness, report\n\
         \x20      fig-lua --version | --help\n\
         \n\
         A script is a Lua 5.4 chunk returning a description of the format and its\n\
         parse, print and render functions; see the crate's `script` module docs.\n",
        env!("CARGO_PKG_VERSION")
    )
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["-h" | "--help" | "help"] => {
            print!("{}", usage());
            ExitCode::SUCCESS
        }
        ["-V" | "--version" | "version"] => {
            println!("fig-lua {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        ["check", script] => check(script),
        [script] => serve(script),
        _ => {
            eprint!("{}", usage());
            ExitCode::from(2)
        }
    }
}

fn load(script: &str) -> Result<LuaLanguage, ExitCode> {
    LuaLanguage::from_file(script).map_err(|e| {
        eprintln!("fig-lua: {script}: {e}");
        ExitCode::from(2)
    })
}

fn serve(script: &str) -> ExitCode {
    let lang = match load(script) {
        Ok(l) => l,
        Err(code) => return code,
    };
    match fig::helper::serve(lang) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("fig-lua: {e}");
            ExitCode::FAILURE
        }
    }
}

fn check(script: &str) -> ExitCode {
    let lang = match load(script) {
        Ok(l) => l,
        Err(code) => return code,
    };
    let d = lang.description().clone();
    match fig::language::register(lang) {
        Ok(formats) => {
            let caps = [
                (d.caps.read, "read"),
                (d.caps.edit, "edit"),
                (d.caps.serialize, "serialize"),
            ]
            .iter()
            .filter(|(on, _)| *on)
            .map(|(_, name)| *name)
            .collect::<Vec<_>>()
            .join(" ");
            println!(
                "{}: registered ({caps}); {} dialect(s), {} sample(s) parsed{}{}",
                d.name,
                formats.len(),
                d.samples.len(),
                if d.caps.serialize {
                    ", printed and reparsed to the same tree"
                } else {
                    ""
                },
                if d.caps.edit {
                    ", and took a no-op edit"
                } else {
                    ""
                },
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{}: refused: {e}", d.name);
            ExitCode::FAILURE
        }
    }
}
