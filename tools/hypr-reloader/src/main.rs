mod cli;
mod config;
mod daemon;
mod hyprland;
mod restore;

use clap::Parser;
use cli::{Cli, Commands};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Snapshot => {
            let windows = hyprland::get_windows().await?;
            println!("{}", serde_json::to_string_pretty(&windows)?);
        }
        Commands::Daemon => {
            daemon::run_daemon().await?;
        }
        Commands::Restore => {
            restore::run_restore().await?;
        }
        Commands::RestoreTemplate => {
            restore::run_restore_template().await?;
        }
    }

    Ok(())
}