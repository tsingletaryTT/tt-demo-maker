mod compile;
mod compress;
mod doctor;
mod manifest;
mod orchestrate;
mod post;
mod publish;
mod ready;
mod record;
mod rehearse;
mod render;
mod scaffold;
mod verify;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "tt-demo", about = "Manifest -> demo footage + draft post")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Preflight: check that required tools are installed.
    Doctor {
        /// Also hard-fail when the optional GUI/screen-capture path is unusable
        /// (no obs/spectacle backend, or no Pillow to verify captures with).
        #[arg(long)]
        require_screen: bool,
    },
    /// Idle-trim a raw asciicast.
    Compress {
        cast: std::path::PathBuf,
        #[arg(long, default_value_t = 1.2)]
        max_idle: f64,
        #[arg(long)]
        out: Option<std::path::PathBuf>,
        /// Print the trimmed cast to stdout instead of writing a file.
        #[arg(long)]
        stdout: bool,
    },
    /// Record one scene, several, or all (with --dry-run to plan only).
    Record {
        /// Scene ids; omit or `all` for every scene.
        ids: Vec<String>,
        #[arg(long)]
        dry_run: bool,
    },
    /// Dry-run a scene's directive against real telemetry (no recording): run it
    /// while sampling tt-smi and report the idle -> load delta per device.
    Rehearse {
        /// Scene id.
        id: String,
        /// Minimum watts of power delta that counts as a reaction.
        #[arg(long, default_value_t = 10.0)]
        min_delta: f64,
        /// Exit nonzero when no reaction is detected (for scripted preflights).
        #[arg(long)]
        require_reaction: bool,
    },
    /// Render a recorded scene's cast into a GIF and/or MP4 artifact.
    Render {
        /// Scene id (must exist in demo/demos.yaml and already be recorded).
        id: String,
        #[arg(long)]
        gif: bool,
        #[arg(long)]
        mp4: bool,
    },
    /// Tile frames of a rendered artifact into a contact-sheet PNG for visual QA.
    Verify {
        /// Scene id (must already be rendered with `tt-demo render`).
        id: String,
        /// How many evenly-spaced frames to tile.
        #[arg(long, default_value_t = 6)]
        frames: u32,
    },
    /// Scaffold demo/ (demos.yaml, assets/, .gitignore) in the current directory.
    Init,
    /// List scenes from demo/demos.yaml with their resolved engine + recorded status.
    List,
    /// Assemble demo/POST.draft.md from the manifest + captions.
    Post {
        /// Narration mode: `none` (caption verbatim), `local` (prompt-server), `claude` (marker
        /// for the skill to fill). Unknown values fall back to `none`.
        #[arg(long, default_value = "none")]
        narrate: String,
    },
    /// Copy rendered artifacts into a committed dir and emit a markdown gallery.
    Publish {
        /// Scene ids; omit or `all` for every scene with a rendered artifact.
        ids: Vec<String>,
        /// Destination directory for published artifacts.
        #[arg(long, default_value = "media")]
        dir: String,
        /// Splice the gallery into this file between tt-demo:gallery markers.
        #[arg(long)]
        readme: Option<std::path::PathBuf>,
    },
}

fn main() -> anyhow::Result<()> {
    // Restore the default (kill-the-process) SIGPIPE disposition. Rust's runtime sets
    // SIGPIPE to SIG_IGN on startup, which turns a downstream reader closing early (e.g.
    // `tt-demo record --dry-run | grep -q ...`, exactly what the golden e2e test does) into
    // an `Err(BrokenPipe)` from the next `println!`/`print!` — and those macros `.unwrap()`
    // internally, so the whole process panics instead of exiting quietly like every other
    // well-behaved Unix CLI. Resetting to SIG_DFL here (before any output) makes a closed
    // stdout pipe just terminate us via the signal, matching normal `grep -q`/`head` idioms.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    match Cli::parse().cmd {
        Cmd::Doctor { require_screen } => doctor::run(require_screen),
        Cmd::Compress { cast, max_idle, out, stdout } => {
            compress::run(&cast, max_idle, out.as_deref(), stdout)
        }
        Cmd::Record { ids, dry_run } => {
            let ids = if ids.is_empty() || ids == ["all"] { None } else { Some(ids) };
            record::run(ids, dry_run)
        }
        Cmd::Rehearse { id, min_delta, require_reaction } => {
            rehearse::run(&id, min_delta, require_reaction)
        }
        Cmd::Render { id, gif, mp4 } => render::run(&id, gif, mp4),
        Cmd::Verify { id, frames } => verify::run(&id, frames),
        Cmd::Init => scaffold::init(),
        Cmd::List => scaffold::list(),
        Cmd::Post { narrate } => {
            let yaml = std::fs::read_to_string("demo/demos.yaml")
                .map_err(|e| anyhow::anyhow!("reading demo/demos.yaml: {e}"))?;
            let m = manifest::Manifest::from_str(&yaml)?;
            // Unknown --narrate values quietly fall back to `none` rather than erroring,
            // since a typo here shouldn't block producing a usable draft.
            let mode = match narrate.as_str() {
                "local" => post::Narrate::Local,
                "claude" => post::Narrate::Claude,
                _ => post::Narrate::None,
            };
            let templates_dir = std::env::var("TT_DEMO_HOME").map(std::path::PathBuf::from)
                .unwrap_or_else(|_| std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."))
                .join("templates");
            let md = post::assemble(&m, mode, &templates_dir)?;
            std::fs::write("demo/POST.draft.md", &md)
                .map_err(|e| anyhow::anyhow!("writing demo/POST.draft.md: {e}"))?;
            println!("wrote demo/POST.draft.md");
            Ok(())
        }
        Cmd::Publish { ids, dir, readme } => {
            let ids = if ids.is_empty() || ids == ["all"] { None } else { Some(ids) };
            publish::run(ids, &dir, readme.as_deref())
        }
    }
}
