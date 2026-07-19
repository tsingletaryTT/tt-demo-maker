mod compress;
mod doctor;
mod manifest;
mod ready;

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
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().cmd {
        Cmd::Doctor => doctor::run(),
        Cmd::Compress { cast, max_idle, out } => compress::run(&cast, max_idle, out.as_deref()),
    }
}
