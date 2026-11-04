use anyhow::{bail, Context, Result};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;
use std::time::Instant;
use tokio::process::Command;
use tokio::time::{sleep, Duration};

use crate::config::get_state_file_path;
use crate::hyprland::{get_windows, WindowInfo};

const WINDOW_TIMEOUT: Duration = Duration::from_secs(15);
const WINDOW_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub async fn run_restore() -> Result<()> {
    let state_file = get_state_file_path()?;
    if !state_file.exists() {
        println!("No saved session found at {:?}", state_file);
        return Ok(());
    }

    let content = fs::read_to_string(&state_file)?;
    let saved_windows: Vec<WindowInfo> = serde_json::from_str(&content)?;
    if saved_windows.is_empty() {
        println!("Saved session contains no windows");
        return Ok(());
    }

    let mut workspaces: BTreeMap<i32, Vec<WindowInfo>> = BTreeMap::new();
    for window in saved_windows {
        if window.workspace_id > 0 {
            workspaces.entry(window.workspace_id).or_default().push(window);
        } else {
            println!(
                "[INFO] Skipping window '{}' on special/invalid workspace {}",
                window.class, window.workspace_id
            );
        }
    }

    for (workspace_id, windows) in workspaces {
        if let Err(error) = restore_workspace_windows(workspace_id, windows).await {
            eprintln!("[ERROR] Workspace {}: {error:#}", workspace_id);
        }
    }

    Ok(())
}

pub async fn run_restore_template() -> Result<()> {
    let home = std::env::var("HOME")?;
    let template_file = Path::new(&home).join(".local/state/hypr_reloader/template.json");
    if !template_file.exists() {
        println!("Template file not found at {:?}", template_file);
        return Ok(());
    }

    let content = fs::read_to_string(&template_file)?;
    let saved_windows: Vec<WindowInfo> = serde_json::from_str(&content)?;
    restore_workspace_windows(4, saved_windows).await
}

pub async fn restore_workspace_windows(workspace_id: i32, mut windows: Vec<WindowInfo>) -> Result<()> {
    windows.sort_by(|left, right| {
        left.at.1.cmp(&right.at.1).then(left.at.0.cmp(&right.at.0))
    });

    println!(
        "[INFO] Restoring workspace {} ({} windows)",
        workspace_id,
        windows.len()
    );

    let (floating_windows, tiled_windows): (Vec<_>, Vec<_>) =
        windows.into_iter().partition(|window| window.floating);

    // A window is matched by its class, not by the appearance of any unrelated window.
    // Keep addresses claimed during this restore to avoid reusing a previously matched window.
    let mut claimed_addresses: HashSet<String> = HashSet::new();

    for (index, window) in tiled_windows.iter().enumerate() {
        println!(
            "[INFO] Tiled window {}/{}: {}",
            index + 1,
            tiled_windows.len(),
            window.class
        );
        let before = get_windows().await?;
        let center_x = window.at.0 + window.size.0 / 2;
        let center_y = window.at.1 + window.size.1 / 2;
        let mut horizontal_split = true;
        let mut split_direction: Option<&str> = None;

        if index > 0 {
            let parent = before.iter()
                .filter(|current| current.workspace_id == workspace_id && !current.floating)
                .find(|current| {
                    center_x >= current.at.0
                        && center_x <= current.at.0 + current.size.0
                        && center_y >= current.at.1
                        && center_y <= current.at.1 + current.size.1
                });

            if let Some(parent) = parent {
                focus_window(&parent.address).await?;
                let relative_x = window.at.0 - parent.at.0;
                let relative_y = window.at.1 - parent.at.1;
                let direction = if relative_x.abs() >= relative_y.abs() {
                    horizontal_split = true;
                    if relative_x < 0 { "l" } else { "r" }
                } else {
                    horizontal_split = false;
                    if relative_y < 0 { "u" } else { "d" }
                };
                split_direction = Some(direction);
                dispatch(&format!("hl.dsp.layout({})", lua_string(&format!("preselect {direction}"))?)).await?;
            } else {
                eprintln!("[WARN] No parent tiling window found for {}", window.class);
            }
        }

        if let Err(error) = spawn_window(window, workspace_id, false).await {
            eprintln!("[ERROR] Cannot launch {}: {error:#}", window.class);
            continue;
        }

        let created = wait_for_window(window, workspace_id, false, &before, &claimed_addresses).await?;
        let Some(created) = created else {
            eprintln!("[WARN] Timed out waiting for {}", window.class);
            continue;
        };
        claimed_addresses.insert(created.address.clone());
        println!("[INFO] Found {} at {}", window.class, created.address);

        if index > 0 {
            let latest = get_windows().await?
                .into_iter()
                .find(|candidate| candidate.address == created.address);
            if let Some(latest) = latest {
                let (mut delta_x, mut delta_y) = if horizontal_split {
                    (window.size.0 - latest.size.0, 0)
                } else {
                    (0, window.size.1 - latest.size.1)
                };
                if split_direction == Some("r") { delta_x = -delta_x; }
                if split_direction == Some("d") { delta_y = -delta_y; }

                if delta_x.abs() > 5 || delta_y.abs() > 5 {
                    focus_window(&created.address).await?;
                    dispatch(&format!(
                        "hl.dsp.window.resize({{ x = {delta_x}, y = {delta_y}, relative = true }})"
                    )).await?;
                }
            }
        }
    }

    for window in &floating_windows {
        println!("[INFO] Floating window: {}", window.class);
        let before = get_windows().await?;
        if let Err(error) = spawn_window(window, workspace_id, true).await {
            eprintln!("[ERROR] Cannot launch {}: {error:#}", window.class);
            continue;
        }
        if let Some(created) = wait_for_window(window, workspace_id, true, &before, &claimed_addresses).await? {
            claimed_addresses.insert(created.address.clone());
            println!("[INFO] Found floating {} at {}", window.class, created.address);
        } else {
            eprintln!("[WARN] Timed out waiting for floating {}", window.class);
        }
    }
    Ok(())
}

async fn wait_for_window(
    saved: &WindowInfo,
    workspace_id: i32,
    floating: bool,
    before: &[WindowInfo],
    claimed_addresses: &HashSet<String>,
) -> Result<Option<WindowInfo>> {
    let started = Instant::now();
    while started.elapsed() < WINDOW_TIMEOUT {
        sleep(WINDOW_POLL_INTERVAL).await;
        let current = get_windows().await?;
        if let Some(found) = current.into_iter().find(|candidate| {
            candidate.workspace_id == workspace_id
                && candidate.floating == floating
                && candidate.class == saved.class
                && !claimed_addresses.contains(&candidate.address)
                && !before.iter().any(|old| old.address == candidate.address)
        }) {
            println!("[DEBUG] {} appeared after {} ms", saved.class, started.elapsed().as_millis());
            return Ok(Some(found));
        }
    }
    Ok(None)
}

async fn focus_window(address: &str) -> Result<()> {
    let selector = lua_string(&format!("address:{address}"))?;
    dispatch(&format!("hl.dsp.focus({{ window = {selector} }})")).await
}

async fn spawn_window(window: &WindowInfo, workspace_id: i32, floating: bool) -> Result<()> {
    if window.cmdline.is_empty() {
        bail!("No command line saved for '{}'", window.class);
    }

    // Preserve each argv element. cmdline.join(" ") loses quoting and breaks paths with spaces.
    let args = if window.cmdline.len() == 1 {
        window.cmdline[0].clone()
    } else {
        window.cmdline
            .iter()
            .map(|arg| shell_quote(arg))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let command = match &window.cwd {
        Some(cwd) => format!("cd {} && exec {args}", shell_quote(&cwd.to_string_lossy())),
        None => format!("exec {args}"),
    };

    let mut rules = format!("workspace = {}", lua_string(&format!("{} silent", workspace_id))?);
    if floating {
        rules.push_str(&format!(
            ", float = true, move = {{ {}, {} }}, size = {{ {}, {} }}",
            window.at.0, window.at.1, window.size.0, window.size.1
        ));
    }

    let expression = format!(
        "hl.dsp.exec_cmd({}, {{ {} }})",
        lua_string(&command)?,
        rules
    );
    dispatch(&expression).await
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn lua_string(value: &str) -> Result<String> {
    Ok(serde_json::to_string(value)?)
}

async fn dispatch(lua_expression: &str) -> Result<()> {
    let output = Command::new("hyprctl")
        .args(["dispatch", lua_expression])
        .output()
        .await
        .with_context(|| format!("Failed to execute hyprctl dispatch: {lua_expression}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() || stdout.trim() != "ok" {
        bail!(
            "Hyprland dispatcher error: {lua_expression}\nstdout: {}\nstderr: {}",
            stdout.trim(),
            stderr.trim()
        );
    }
    Ok(())
}
