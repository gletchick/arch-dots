use anyhow::{Context, Result};
use std::fs;
use std::path::PathBuf;

pub fn get_state_file_path() -> Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME environment variable not set")?;
    let path = PathBuf::from(home).join(".local/state/hypr_reloader");
    fs::create_dir_all(&path)?;
    Ok(path.join("session.json"))
}

pub fn save_state_atomic(path: &PathBuf, content: &str) -> Result<()> {
    let tmp_path = path.with_extension("tmp");
    fs::write(&tmp_path, content)?;
    fs::rename(tmp_path, path)?;
    Ok(())
}