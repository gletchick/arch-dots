#!/usr/bin/env bash
set -u
SETTINGS_FILE="$HOME/.config/hypr/settings.json"
ENV_FILE="$HOME/.config/hypr/scripts/quickshell/calendar/.env"
WEATHER_SCRIPT="$HOME/.config/hypr/scripts/weather.sh"
CONFIG_DIR="$HOME/.config/hypr/config"
GENERATOR="$HOME/.config/hypr/scripts/generate_lua_config.py"
mkdir -p "$CONFIG_DIR" "$(dirname "$ENV_FILE")"
[ -e "$SETTINGS_FILE" ] || cp "$HOME/.config/hypr/default_settings.json" "$SETTINGS_FILE"

compile_settings() {
    local before after
    before=$(sha256sum "$CONFIG_DIR"/{settings,monitors,keybindings,env,autostart}.lua 2>/dev/null | sha256sum | cut -d' ' -f1)
    if ! python3 "$GENERATOR"; then
        echo "Failed to generate Lua configuration" >&2
        return 1
    fi
    after=$(sha256sum "$CONFIG_DIR"/{settings,monitors,keybindings,env,autostart}.lua 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [[ "$before" != "$after" ]]; then
        echo "Lua config updated, reloading Hyprland"
        hyprctl reload
    fi
}

if [[ "${1:-}" == "--compile" ]]; then
    compile_settings
    exit $?
fi

echo "Watching settings.json and calendar .env"
inotifywait -m -q -e close_write,moved_to --format '%w%f' "$(dirname "$SETTINGS_FILE")" "$(dirname "$ENV_FILE")" | while IFS= read -r filepath; do
    if [[ "$filepath" == "$SETTINGS_FILE" ]]; then
        compile_settings
    elif [[ "$filepath" == "$ENV_FILE" ]]; then
        if [[ -x "$WEATHER_SCRIPT" ]]; then "$WEATHER_SCRIPT" --getdata &
        elif [[ -f "$WEATHER_SCRIPT" ]]; then bash "$WEATHER_SCRIPT" --getdata &
        fi
    fi
done
