mod compile;
mod compress;
mod doctor;
mod manifest;
mod orchestrate;
mod ready;
mod record;

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
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().cmd {
        Cmd::Doctor => doctor::run(),
        Cmd::Compress { cast, max_idle, out } => compress::run(&cast, max_idle, out.as_deref()),
        Cmd::Record { ids, dry_run } => {
            let ids = if ids.is_empty() || ids == ["all"] { None } else { Some(ids) };
            record::run(ids, dry_run)
        }
    }
}
