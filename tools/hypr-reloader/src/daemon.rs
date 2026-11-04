use anyhow::{Context, Result};
use std::env;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixStream;
use tokio::signal::unix::{signal, SignalKind};
use tokio::time::{sleep, Duration, Instant};

use crate::config::{get_state_file_path, save_state_atomic};
use crate::hyprland::get_windows;

pub async fn run_daemon() -> Result<()> {
    let runtime_dir = env::var("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR not set")?;
    let instance_sig =
        env::var("HYPRLAND_INSTANCE_SIGNATURE").context("HYPRLAND_INSTANCE_SIGNATURE not set")?;

    let socket_path = format!("{}/hypr/{}/.socket2.sock", runtime_dir, instance_sig);
    let state_file = get_state_file_path()?;

    let mut sigterm = signal(SignalKind::terminate())?;
    let mut last_save = Instant::now();

    if let Ok(stream) = UnixStream::connect(&socket_path).await {
        let mut reader = BufReader::new(stream).lines();

        loop {
            tokio::select! {
                _ = sigterm.recv() => {
                    break;
                }
                line_res = reader.next_line() => {
                    match line_res {
                        Ok(Some(line)) => {
                            if line.starts_with("openwindow>>")
                                || line.starts_with("closewindow>>")
                                || line.starts_with("movewindow>>")
                            {
                                if last_save.elapsed() > Duration::from_secs(2) {
                                    if let Ok(windows) = get_windows().await {
                                        if let Ok(json) = serde_json::to_string_pretty(&windows) {
                                            let _ = save_state_atomic(&state_file, &json);
                                            last_save = Instant::now();
                                        }
                                    }
                                }
                            }
                        }
                        _ => break,
                    }
                }
            }
        }
    } else {
        loop {
            tokio::select! {
                _ = sigterm.recv() => {
                    break;
                }
                _ = sleep(Duration::from_secs(10)) => {
                    if let Ok(windows) = get_windows().await {
                        if let Ok(json) = serde_json::to_string_pretty(&windows) {
                            let _ = save_state_atomic(&state_file, &json);
                        }
                    }
                }
            }
        }
    }

    Ok(())
}