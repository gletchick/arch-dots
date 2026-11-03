# Hyprland 0.57 — Lua migration of imperative-dots

This overlay contains **only changed files**, relative to your HOME directory. Everything else (Quickshell, scripts, pictures) stays as on your machine.

## Install safely

```bash
# From the folder containing the unpacked .config directory:
cp -a ~/.config/hypr ~/.config/hypr.backup-before-lua
cp -a .config/hypr/. ~/.config/hypr/
# Optional: run generator to switch immediately to values from your current settings.json
# python3 ~/.config/hypr/scripts/generate_lua_config.py
hyprctl reload
hyprctl configerrors
```

IMPORTANT: Existing `settings.json` must not be overwritten. It is not present in the overlay.

Alternatively run `bash install-lua.sh` from the unpacked overlay to back up and copy the files (it does not reload automatically).

There is no need to remove old `.conf` files. They are ignored by Hyprland 0.57; but `hypridle.conf`, `hyprlock.conf`, etc. are configs of separate utilities and must remain.

**Differences:** `blur.new_optimizations` is preserved; Matugen border colors are read from `colors.conf` as a data source on reload; `hl.exec_cmd` calls at startup are asynchronous, so `&` removed. `settings_watcher.sh` now generates Lua instead of `.conf`.

This migration was statically reviewed, but cannot be run with your live Hyprland/Quickshell/monitor hardware from here. After applying, check errors and actual behavior. If needed, restore using `cp -a ~/.config/hypr.backup-before-lua/. ~/.config/hypr/`.

When editing keybinds in Quickshell, generated config is based on your current `settings.json`, not the static configs in the archive. The archive's `default_settings.json` differs from static config/keybindings.conf and autostart.conf; your local `settings.json` is the authoritative source for future edits.
