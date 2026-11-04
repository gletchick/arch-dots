use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use tokio::process::Command;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WindowInfo {
    pub address: String,
    pub workspace_id: i32,
    pub class: String,
    pub title: String,
    pub pid: u32,
    pub cwd: Option<PathBuf>,
    pub cmdline: Vec<String>,
    pub floating: bool,
    pub at: (i32, i32),
    pub size: (i32, i32),
}

#[derive(Deserialize)]
struct HyprClient {
    address: String,
    workspace: HyprWorkspace,
    class: String,
    title: String,
    pid: u32,
    floating: bool,
    at: (i32, i32),
    size: (i32, i32),
}

#[derive(Deserialize)]
struct HyprWorkspace {
    id: i32,
}

pub async fn get_windows() -> Result<Vec<WindowInfo>> {
    let output = Command::new("hyprctl")
        .args(["clients", "-j"])
        .output()
        .await
        .context("Failed to execute hyprctl clients -j")?;

    if !output.status.success() {
        bail!(
            "hyprctl clients -j failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    let clients: Vec<HyprClient> = serde_json::from_slice(&output.stdout)
        .context("Failed to parse hyprctl clients JSON")?;

    let mut windows = Vec::new();
    for client in clients {
        if client.pid == 0 || client.class.is_empty() {
            continue;
        }

        let cwd = fs::read_link(format!("/proc/{}/cwd", client.pid)).ok();
        let cmdline = fs::read(format!("/proc/{}/cmdline", client.pid))
            .map(|bytes| {
                bytes
                    .split(|byte| *byte == 0)
                    .filter(|arg| !arg.is_empty())
                    .map(|arg| String::from_utf8_lossy(arg).into_owned())
                    .collect()
            })
            .unwrap_or_default();

        windows.push(WindowInfo {
            address: client.address,
            workspace_id: client.workspace.id,
            class: client.class,
            title: client.title,
            pid: client.pid,
            cwd,
            cmdline,
            floating: client.floating,
            at: client.at,
            size: client.size,
        });
    }

    Ok(windows)
}
