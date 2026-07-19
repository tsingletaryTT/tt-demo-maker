mod compile;
mod compress;
mod doctor;
mod manifest;
mod orchestrate;
mod post;
mod ready;
mod record;
mod render;
mod scaffold;

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
    Doctor,
    /// Idle-trim a raw asciicast.
    Compress {
        cast: std::path::PathBuf,
        #[arg(long, default_value_t = 1.2)]
        max_idle: f64,
        #[arg(long)]
        out: Option<std::path::PathBuf>,
    },
    /// Record one scene, several, or all (with --dry-run to plan only).
    Record {
        /// Scene ids; omit or `all` for every scene.
        ids: Vec<String>,
        #[arg(long)]
        dry_run: bool,
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
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().cmd {
        Cmd::Doctor => doctor::run(),
        Cmd::Compress { cast, max_idle, out } => compress::run(&cast, max_idle, out.as_deref()),
        Cmd::Record { ids, dry_run } => {
            let ids = if ids.is_empty() || ids == ["all"] { None } else { Some(ids) };
            record::run(ids, dry_run)
        }
        Cmd::Render { id, gif, mp4 } => render::run(&id, gif, mp4),
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
    }
}
