#!/usr/bin/env bash

set -uo pipefail

bin="$HOME/.local/bin/hypr_reloader"
logDir="$HOME/.local/state/hypr_reloader"
logFile="$logDir/restore.log"

mkdir -p "$logDir"

{
    echo ""
    echo "========== $(date '+%F %T') =========="
    echo "[INFO] Starting session restore"

    systemctl --user import-environment \
        HYPRLAND_INSTANCE_SIGNATURE \
        WAYLAND_DISPLAY \
        XDG_CURRENT_DESKTOP || exit 1

    if [[ ! -x "$bin" ]]; then
        echo "[WARNING] hypr_reloader is not installed"
        exit 0
    fi

    echo "[INFO] Restoring windows"

    if "$bin" restore; then
        echo "[INFO] Restore completed"
    else
        echo "[ERROR] Restore failed"
    fi

    echo "[INFO] Starting daemon"
    systemctl --user start hypr-reloader.service

    echo "[INFO] Script finished"

} >> "$logFile" 2>&1