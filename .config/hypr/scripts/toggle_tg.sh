#!/usr/bin/env bash
# Toggle Telegram in the named Hyprland Lua special workspace "tg".
set -euo pipefail

# Hyprland 0.55+ uses Lua dispatchers; legacy dispatcher names do not work here.
telegram_window=$(hyprctl -j clients | jq -c '
  [.[] | select(.class == "org.telegram.desktop" or .class == "TelegramDesktop")][0] // empty
')

if [[ -n "$telegram_window" ]]; then
    telegram_workspace=$(jq -r '.workspace.name // ""' <<< "$telegram_window")
    if [[ "$telegram_workspace" != "special:tg" ]]; then
        telegram_address=$(jq -r '.address' <<< "$telegram_window")
        hyprctl dispatch "hl.dsp.window.move({ workspace = \"special:tg\", window = \"address:$telegram_address\", follow = false })"
    fi
else
    # The Telegram window rule places new windows directly in special:tg.
    if command -v Telegram >/dev/null 2>&1; then
        Telegram >/dev/null 2>&1 &
    elif command -v telegram-desktop >/dev/null 2>&1; then
        telegram-desktop >/dev/null 2>&1 &
    else
        echo 'Telegram executable not found (Telegram or telegram-desktop).' >&2
        exit 1
    fi
fi

hyprctl dispatch 'hl.dsp.workspace.toggle_special("tg")'
