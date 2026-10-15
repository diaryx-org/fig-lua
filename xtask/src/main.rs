//! fig-lua's CI, as one program.
//!
//! Every job the CI workflow runs is one entry in [`JOBS`] and one
//! `cargo xtask <id>` invocation. The workflow itself holds no build knowledge:
//! it asks `cargo xtask ci-matrix` what the jobs are, then runs each one by id.
//! Adding, renaming, reordering, or retiring a job is an edit to this file and
//! nothing else — the YAML does not change.
//!
//! Locally, `cargo xtask ci` runs the same jobs in the same order against the
//! same commands, so a green run here is a green run there.
//!
//! Cutting a release does not live here. It is `release`, the shared
//! tooling configured by `.config/release.toml` — the same tool prov, twig,
//! leaf, flower, and the historica repos all cut releases with, because five
//! copies of one program is five places for it to drift.
//!
//! There are no dependencies on purpose. Every CI job builds this crate before
//! it can start, so its build time is paid several times over per push.

use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

/// Anything that goes wrong here is a message for whoever is reading the log;
/// there is nothing for a CI runner to recover from.
type Result<T> = std::result::Result<T, String>;

/// One CI job: what to call it, what the runner must install for it, and the
/// work itself.
struct Job {
    /// `cargo xtask <id>`, and the key the workflow dispatches on.
    id: &'static str,
    /// The name GitHub shows in the checks list. Renaming it renames the
    /// required status check, so branch protection has to be updated to match.
    name: &'static str,
    /// rustup components the job needs, comma-joined for
    /// `dtolnay/rust-toolchain`. Empty means the default toolchain is enough.
    components: &'static str,
    /// Does this job *compile* the crate? If so, restoring the cargo cache is
    /// worth its cost. `fmt` is the one job that only ever parses.
    builds: bool,
    /// One line of explanation, printed by `cargo xtask` with no arguments.
    about: &'static str,
    run: fn(&Sh) -> Result<()>,
}

/// The whole of CI, in the order `cargo xtask ci` runs it: cheapest and most
/// likely to fail first.
const JOBS: &[Job] = &[
    Job {
        id: "fmt",
        name: "Format",
        components: "rustfmt",
        builds: false,
        about: "rustfmt, in check mode",
        run: fmt,
    },
    Job {
        id: "clippy",
        name: "Clippy",
        components: "clippy",
        builds: true,
        about: "clippy over every target, warnings denied",
        run: clippy,
    },
    Job {
        id: "test",
        name: "Test",
        components: "",
        builds: true,
        about: "the workspace test suite, doctests included",
        run: test,
    },
    Job {
        id: "doc",
        name: "Docs",
        components: "",
        builds: true,
        about: "rustdoc with warnings denied — a broken intra-doc link is a broken link",
        run: doc,
    },
    Job {
        id: "msrv",
        name: "MSRV",
        components: "",
        builds: true,
        about: "build on the minimum supported Rust version",
        run: msrv,
    },
];

// ---------------------------------------------------------------------------
// The jobs
// ---------------------------------------------------------------------------

fn fmt(sh: &Sh) -> Result<()> {
    sh.cargo(&["fmt", "--all", "--check"])
}

/// Warnings are errors in CI, so they are errors here too — a lint that only
/// fires on the runner is a lint found too late.
fn clippy(sh: &Sh) -> Result<()> {
    sh.cargo(&[
        "clippy",
        "--workspace",
        "--all-targets",
        "--",
        "-D",
        "warnings",
    ])
}

/// The workspace test suite. `--all-targets` is deliberately *not* passed:
/// it excludes doctests, and this crate's documentation carries most of its
/// worked examples.
fn test(sh: &Sh) -> Result<()> {
    sh.cargo(&["test", "--workspace"])
}

/// Rustdoc, with warnings denied.
///
/// Worth a job of its own here more than in most crates: nearly every type in
/// this one is documented by pointing at another (`Consequence` at `Tint`,
/// `FindingKind::TintNotRead` at `Tint::ALL`), and an intra-doc link that stops
/// resolving takes the explanation with it while the code still compiles.
fn doc(sh: &Sh) -> Result<()> {
    sh.run_with(
        &[("RUSTDOCFLAGS", "-D warnings")],
        &sh.cargo.clone(),
        &["doc", "--workspace", "--no-deps"],
    )
}

/// Build on the crate's declared minimum supported Rust version. A build, not a
/// test run: MSRV is a promise about who can *compile* fig-lua, and the
/// dev-dependencies and test tooling need not hold to it.
///
/// The version is read from `workspace.package.rust-version`, so the pin can
/// never drift from the declared floor — bump it in Cargo.toml and this follows.
fn msrv(sh: &Sh) -> Result<()> {
    let version = sh.workspace_rust_version()?;
    println!("MSRV from Cargo.toml: {version}");
    // Idempotent: rustup reports an already-installed toolchain and returns 0.
    sh.run(
        "rustup",
        &[
            "toolchain",
            "install",
            &version,
            "--profile",
            "minimal",
            "--no-self-update",
        ],
    )
    .map_err(|e| format!("{e}\n\nthe MSRV job needs rustup on PATH to pin Rust {version}"))?;
    // `rustup run`, not `cargo +{version}`: the `+toolchain` shorthand is a
    // rustup-proxy feature, and $CARGO may well point past the proxy at a real
    // toolchain binary that does not understand it.
    sh.run(
        "rustup",
        &["run", &version, "cargo", "build", "--workspace"],
    )
}

// ---------------------------------------------------------------------------
// Driving them
// ---------------------------------------------------------------------------

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let sh = Sh::new();

    let outcome = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        [] | ["-h" | "--help" | "help"] => {
            print!("{}", usage());
            return ExitCode::SUCCESS;
        }
        ["ci"] => ci(&sh),
        ["ci-matrix"] => {
            println!("{}", ci_matrix());
            Ok(())
        }
        // Releasing is the shared tool's, and a muscle-memory `cargo xtask
        // release` should say where it went rather than report an unknown job.
        [
            command @ ("version" | "bump" | "changelog" | "release" | "release-notes"),
            ..,
        ] => {
            let moved = match command {
                "release" => "release".to_string(),
                "release-notes" => "release notes".to_string(),
                other => format!("release {other}"),
            };
            Err(format!(
                "releasing is not in xtask: `cargo xtask {command}` is `{moved}`,\n\
             the shared tooling this repo configures in .config/release.toml.\n\n{}",
                usage()
            ))
        }
        [id] => match JOBS.iter().find(|job| job.id == id) {
            Some(job) => (job.run)(&sh),
            None => Err(format!("unknown job `{id}`\n\n{}", usage())),
        },
        [id, ..] => Err(format!("`{id}` takes no arguments\n\n{}", usage())),
    };

    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("\nxtask: {message}");
            ExitCode::FAILURE
        }
    }
}

/// Every job, in order — what CI does, on one machine. Stops at the first
/// failure, on the theory that a red build is worth reading before the next one
/// buries it.
fn ci(sh: &Sh) -> Result<()> {
    for job in JOBS {
        println!("\n\x1b[1m━━ {} ━━\x1b[0m", job.name);
        (job.run)(sh)?;
    }
    println!("\n\x1b[32mall {} jobs passed\x1b[0m", JOBS.len());
    Ok(())
}

/// The job table as a single line of JSON, for the workflow's `strategy.matrix`.
///
/// Hand-rolled rather than serde-derived: the crate has no dependencies, and
/// every value here is a `&'static str` literal from [`JOBS`] with nothing in it
/// that JSON would need escaped. A job name with a quote or a backslash in it
/// would produce invalid JSON, and the test below is what would notice.
fn ci_matrix() -> String {
    let entries: Vec<String> = JOBS
        .iter()
        .map(|job| {
            format!(
                r#"{{"id":"{}","name":"{}","components":"{}","builds":{}}}"#,
                job.id, job.name, job.components, job.builds
            )
        })
        .collect();
    format!("[{}]", entries.join(","))
}

fn usage() -> String {
    let mut out = String::from(
        "fig-lua's CI, as a program. Each job below is exactly what the CI \
         workflow runs.\n\nusage: cargo xtask <command>\n\njobs:\n\n",
    );
    for job in JOBS {
        out.push_str(&format!("  {:<20}{}\n", job.id, job.about));
    }
    out.push_str(&format!("  {:<20}{}\n", "ci", "every job above, in order"));
    out.push_str(&format!(
        "  {:<20}{}\n",
        "ci-matrix", "the job table as JSON, for the workflow matrix"
    ));
    out.push_str("\nreleasing:  dx <command>   (the shared tooling; see .config/release.toml)\n");
    out
}

// ---------------------------------------------------------------------------
// Running things
// ---------------------------------------------------------------------------

/// A shell rooted at the workspace, so a job never has to think about where it
/// was invoked from.
struct Sh {
    root: PathBuf,
    /// Cargo tells its subprocesses which cargo it is; prefer that over
    /// whichever one happens to be first on PATH.
    cargo: String,
}

impl Sh {
    fn new() -> Self {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("xtask/ always has a parent")
            .to_path_buf();
        let cargo = env::var("CARGO").unwrap_or_else(|_| "cargo".into());
        Sh { root, cargo }
    }

    fn cargo(&self, args: &[&str]) -> Result<()> {
        let cargo = self.cargo.clone();
        self.run(&cargo, args)
    }

    /// Run a command at the workspace root, echoing it first so a CI log reads
    /// as a transcript of commands anyone can paste back.
    fn run(&self, program: &str, args: &[&str]) -> Result<()> {
        self.run_with(&[], program, args)
    }

    /// The same, with environment — echoed in front of the command, since a
    /// transcript that leaves out what the command was told is not one.
    fn run_with(&self, environment: &[(&str, &str)], program: &str, args: &[&str]) -> Result<()> {
        let shown = if program == self.cargo {
            "cargo"
        } else {
            program
        };
        let prefix: String = environment
            .iter()
            .map(|(name, value)| format!("{name}={value} "))
            .collect();
        println!("\x1b[2m$ {prefix}{} {}\x1b[0m", shown, args.join(" "));

        let status = Command::new(program)
            .args(args)
            .envs(environment.iter().copied())
            .current_dir(&self.root)
            .status()
            .map_err(|e| format!("could not run `{shown}`: {e}"))?;

        if status.success() {
            Ok(())
        } else {
            Err(format!(
                "`{prefix}{shown} {}` failed ({status})",
                args.join(" ")
            ))
        }
    }

    /// `workspace.package.rust-version`, the single source of truth for the MSRV.
    fn workspace_rust_version(&self) -> Result<String> {
        let manifest = self.root.join("Cargo.toml");
        let text = std::fs::read_to_string(&manifest)
            .map_err(|e| format!("could not read {}: {e}", manifest.display()))?;
        text.lines()
            .find_map(|line| {
                let line = line.trim();
                // `rust-version.workspace = true` in `[package]` is the
                // inheriting side of this value, not the value itself.
                let rest = line.strip_prefix("rust-version")?;
                rest.split('"').nth(1)
            })
            .map(str::to_owned)
            .ok_or_else(|| format!("no `rust-version` in {}", manifest.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The workflow's `fromJSON` is the only thing that parses `ci-matrix`, and
    /// it fails at a point where the fix costs a push. Check the shape here
    /// instead: one object per job, every field present, nothing needing an
    /// escape.
    #[test]
    fn ci_matrix_is_well_formed_json() {
        let json = ci_matrix();
        assert!(json.starts_with('[') && json.ends_with(']'));
        assert_eq!(json.matches("\"id\":").count(), JOBS.len());
        assert_eq!(json.lines().count(), 1, "the workflow reads it as one line");

        for job in JOBS {
            for field in [job.id, job.name, job.components] {
                assert!(
                    !field.contains(['"', '\\']),
                    "`{field}` would need JSON escaping, which ci_matrix does not do",
                );
            }
            assert!(json.contains(&format!("\"id\":\"{}\"", job.id)));
        }
    }

    /// `ci` and `ci-matrix` are handled before the table is consulted, so a job
    /// by either name would be unreachable.
    #[test]
    fn job_ids_are_distinct_and_dispatchable() {
        let mut ids: Vec<&str> = JOBS.iter().map(|job| job.id).collect();
        let count = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), count, "duplicate job id");
        assert!(!ids.contains(&"ci") && !ids.contains(&"ci-matrix"));
    }

    /// The MSRV job reads this; if the parse breaks, the job silently pins the
    /// wrong compiler or fails far from the cause. `[package]` inherits the
    /// value with `rust-version.workspace = true`, which is a line the parse has
    /// to walk past rather than read.
    #[test]
    fn msrv_is_readable_from_the_manifest() {
        let version = Sh::new().workspace_rust_version().unwrap();
        assert!(
            version.split('.').all(|part| part.parse::<u32>().is_ok()),
            "`{version}` does not look like a Rust version",
        );
    }
}
