mod doctor;
mod manifest;

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
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().cmd {
        Cmd::Doctor => doctor::run(),
    }
}
