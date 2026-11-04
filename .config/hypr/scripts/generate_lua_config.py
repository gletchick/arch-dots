
#!/usr/bin/env python3
"""Generate Hyprland 0.57+ Lua configs from settings.json."""

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path.home() / ".config/hypr"
CONFIG_DIR = ROOT / "config"
TEMPLATE_DIR = ROOT / "templates"

SETTINGS_FILE = ROOT / "settings.json"
DEFAULT_SETTINGS_FILE = ROOT / "default_settings.json"

DEFAULT_TERMINAL = "kitty"

DIRECTIONS = {
    "l": "left",
    "r": "right",
    "u": "up",
    "d": "down",
}

BIND_FLAGS = {
    "bind": {},
    "binde": {"repeating": True},
    "bindl": {"locked": True},
    "bindel": {"locked": True, "repeating": True},
    "bindm": {"mouse": True},
}


def load_settings():
    source = (
        SETTINGS_FILE
        if SETTINGS_FILE.is_file()
        else DEFAULT_SETTINGS_FILE
    )

    if not source.is_file():
        raise FileNotFoundError("settings.json not found")

    with source.open(encoding="utf-8") as file:
        settings = json.load(file)

    if not isinstance(settings, dict):
        raise ValueError("Settings root must be a JSON object")

    return settings


def lua_string(value):
    return json.dumps(str(value), ensure_ascii=False)


def lua_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"

    if isinstance(value, (int, float)):
        return str(value)

    return lua_string(value)


def resolve_terminal(command, settings):
    command = str(command).strip()

    terminal = str(
        settings.get("terminal") or DEFAULT_TERMINAL
    ).strip()

    # Replace the legacy Hyprland variable.
    return re.sub(
        r"\$terminal\b",
        lambda _: terminal,
        command,
    )


def normalize_direction(value):
    value = str(value).strip().lower()
    return DIRECTIONS.get(value, value)


def normalize_modifiers(mods, key):
    mods = re.sub(
        r"\$mainMod\b",
        "SUPER",
        str(mods or ""),
        flags=re.IGNORECASE,
    )

    parts = [
        # SHIFT_L / SHIFT_R are keysyms, not modifier names.
        # Normalise legacy settings produced by the UI.
        "SHIFT" if part.upper() in ("SHIFT_L", "SHIFT_R") else part
        for part in re.split(r"[\s&+]+", mods)
        if part.strip()
    ]

    if key:
        parts.append(str(key).strip())

    return " + ".join(parts)


def dispatcher_action(dispatcher, command, settings):
    dispatcher = str(dispatcher).strip().lower()
    command = str(command or "").strip()

    if dispatcher in ("exec", "execr"):
        command = resolve_terminal(command, settings)

        # Convert known legacy hyprctl commands.
        legacy = re.fullmatch(
            r"hyprctl\s+dispatch\s+(\w+)(?:\s+(.*))?",
            command,
        )

        if legacy:
            legacy_dispatcher = legacy.group(1).lower()
            legacy_command = legacy.group(2) or ""

            # Avoid infinite recursion.
            if legacy_dispatcher in ("exec", "execr"):
                return (
                    "hl.dsp.exec_cmd("
                    + lua_string(legacy_command)
                    + ")"
                )

            return dispatcher_action(
                legacy_dispatcher,
                legacy_command,
                settings,
            )

        # Already uses the new Lua dispatch syntax.
        if command.startswith("hyprctl dispatch hl.dsp."):
            return "hl.dsp.exec_cmd(" + lua_string(command) + ")"

        return "hl.dsp.exec_cmd(" + lua_string(command) + ")"

    if dispatcher == "killactive":
        return "hl.dsp.window.close()"

    if dispatcher == "togglefloating":
        return 'hl.dsp.window.float({ action = "toggle" })'

    if dispatcher == "fullscreen":
        mode = (
            "maximized"
            if command == "1"
            else "fullscreen"
        )

        return (
            'hl.dsp.window.fullscreen({ action = "toggle", '
            'mode = ' + lua_string(mode) + " })"
        )

    if dispatcher == "pseudo":
        return "hl.dsp.window.pseudo()"

    if dispatcher == "workspace":
        return (
            "hl.dsp.focus({ workspace = "
            + lua_string(command)
            + " })"
        )

    if dispatcher in ("movetoworkspace", "movetoworkspacesilent"):
        follow = (
            "false"
            if dispatcher == "movetoworkspacesilent"
            else "true"
        )

        return (
            "hl.dsp.window.move({ workspace = "
            + lua_string(command)
            + ", follow = "
            + follow
            + " })"
        )

    if dispatcher == "movefocus":
        return (
            "hl.dsp.focus({ direction = "
            + lua_string(normalize_direction(command))
            + " })"
        )

    if dispatcher == "movewindow":
        return (
            "hl.dsp.window.move({ direction = "
            + lua_string(normalize_direction(command))
            + " })"
        )

    if dispatcher == "focusmonitor":
        return (
            "hl.dsp.focus({ monitor = "
            + lua_string(command)
            + " })"
        )

    if dispatcher == "movewindowtomonitor":
        return (
            "hl.dsp.window.move({ monitor = "
            + lua_string(command)
            + " })"
        )

    if dispatcher == "togglespecialworkspace":
        name = command.removeprefix("special:")

        return (
            "hl.dsp.workspace.toggle_special("
            + lua_string(name)
            + ")"
        )

    if dispatcher == "resizeactive":
        values = command.split()

        if len(values) != 2:
            raise ValueError(
                f"Invalid resizeactive arguments: {command}"
            )

        dx, dy = map(int, values)

        return (
            f"hl.dsp.window.resize({{ x = {dx}, "
            f"y = {dy}, relative = true }})"
        )

    if dispatcher == "moveactive":
        values = command.split()

        if len(values) != 2:
            raise ValueError(
                f"Invalid moveactive arguments: {command}"
            )

        dx, dy = map(int, values)

        return (
            f"hl.dsp.window.move({{ x = {dx}, "
            f"y = {dy}, relative = true }})"
        )

    if dispatcher == "pin":
        return "hl.dsp.window.pin()"

    if dispatcher == "submap":
        return "hl.dsp.submap(" + lua_string(command) + ")"

    if dispatcher == "layoutmsg":
        return "hl.dsp.layout(" + lua_string(command) + ")"

    if dispatcher == "exit":
        return "hl.dsp.exit()"

    raise ValueError(
        f"Unsupported legacy dispatcher: {dispatcher!r}, "
        f"command: {command!r}"
    )


def make_bind(item, settings):
    kind = str(item.get("type", "bind")).lower()

    if kind not in BIND_FLAGS:
        raise ValueError(f"Unsupported bind type: {kind}")

    mods = item.get("mods", "")
    key = item.get("key", "")
    dispatcher = item.get("dispatcher", "exec")
    command = item.get("command", "")

    key_string = normalize_modifiers(mods, key)

    if not key_string:
        raise ValueError("Empty keybinding")

    action = dispatcher_action(
        dispatcher,
        command,
        settings,
    )

    flags = BIND_FLAGS[kind]

    if flags:
        options = ", { " + ", ".join(
            f"{name} = true"
            for name in flags
        ) + " }"
    else:
        options = ""

    return (
        "hl.bind("
        + lua_string(key_string)
        + ", "
        + action
        + options
        + ")"
    )


def emit_binds(settings):
    lines = [
        "-- Generated from settings.json.",
        "-- Do not edit this file manually.",
        "",
        'hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })',
        "",
        'hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })',
        'hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })',
        "",
    ]

    for index, item in enumerate(settings.get("keybinds", [])):
        try:
            lines.append(make_bind(item, settings))
        except (ValueError, TypeError) as error:
            raise ValueError(
                f"Error in keybinds[{index}]: {error}"
            ) from error

    return "\n".join(lines) + "\n"


def emit_autostart(settings):
    commands = [
        str(item.get("command", "")).strip()
        for item in settings.get("startup", [])
        if item.get("command")
    ]

    if settings.get("openGuideAtStartup", True):
        commands.append(
            "bash -c 'sleep 1 && "
            "~/.config/hypr/scripts/qs_manager.sh toggle guide'"
        )

    # Preserve additional startup entries from the old config.
    commands.extend([
        "Telegram",
        "blueman-applet",
    ])

    # This is a required part of the desktop session, not a user-configurable
    # startup application. Keep it even when settings.json is regenerated.
    restore_command = "~/.config/hypr/scripts/restore_session.sh"
    commands = [command for command in commands if command != restore_command]
    commands.append(restore_command)

    lines = [
        "-- Generated from settings.json.",
        'hl.on("hyprland.start", function()',
    ]

    for command in commands:
        command = command.removesuffix(" &").strip()

        lines.append(
            "    hl.exec_cmd(" + lua_string(command) + ")"
        )

    lines.append("end)")

    return "\n".join(lines) + "\n"


def xdg_directory(name, fallback):
    try:
        result = subprocess.run(
            ["xdg-user-dir", name],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )

        return result.stdout.strip() or str(fallback)

    except (FileNotFoundError, subprocess.TimeoutExpired):
        return str(fallback)


def emit_env(settings):
    home = pathlib.Path.home()

    env = {
        "NIXOS_OZONE_WL": "1",
        "XDG_PICTURES_DIR": xdg_directory(
            "PICTURES", home / "Pictures"
        ),
        "XDG_VIDEOS_DIR": xdg_directory(
            "VIDEOS", home / "Videos"
        ),
        "WALLPAPER_DIR": settings.get("wallpaperDir", ""),
        "SCRIPT_DIR": str(ROOT / "scripts"),
        "QT_QPA_PLATFORMTHEME": "qt6ct",
    }

    for entry in settings.get("hardwareEnvs", []):
        if not isinstance(entry, str):
            continue

        match = re.fullmatch(
            r"\s*env\s*=\s*([^,]+)\s*,\s*(.*)",
            entry,
        )

        if match:
            key = match.group(1).strip()
            value = match.group(2).strip()
            env[key] = value

    lines = ["-- Generated environment variables.", ""]

    for key, value in env.items():
        lines.append(
            "hl.env("
            + lua_string(key)
            + ", "
            + lua_string(value)
            + ")"
        )

    return "\n".join(lines) + "\n"


def emit_monitors(settings):
    monitors = settings.get("monitors") or []

    lines = ["-- Generated monitor configuration.", ""]

    if not monitors:
        lines.append(
            'hl.monitor({ output = "", mode = "preferred", '
            'position = "auto", scale = 1 })'
        )

    for monitor in monitors:
        mode = (
            f"{monitor['resW']}x{monitor['resH']}"
            f"@{monitor['rate']}"
        )

        position = f"{monitor['x']}x{monitor['y']}"

        fields = [
            "output = " + lua_string(monitor.get("name", "")),
            "mode = " + lua_string(mode),
            "position = " + lua_string(position),
            "scale = " + lua_value(monitor.get("scale", 1)),
        ]

        if monitor.get("transform") is not None:
            fields.append(
                "transform = " + str(int(monitor["transform"]))
            )

        lines.append(
            "hl.monitor({ " + ", ".join(fields) + " })"
        )

    return "\n".join(lines) + "\n"


def emit_settings(settings):
    template_file = TEMPLATE_DIR / "settings.lua.template"

    if not template_file.is_file():
        raise FileNotFoundError(
            f"Missing template: {template_file}"
        )

    content = template_file.read_text(encoding="utf-8")

    replacements = {
        "{{KB_LAYOUT}}": lua_string(
            settings.get("language", "us")
        ),
        "{{KB_OPTIONS}}": lua_string(
            settings.get("kbOptions", "grp:alt_shift_toggle")
        ),
    }

    for placeholder, value in replacements.items():
        if placeholder not in content:
            raise ValueError(
                f"Missing template placeholder: {placeholder}"
            )

        content = content.replace(placeholder, value)

    return content


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)

    fd, temp_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=path.parent,
    )

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(content)

        os.replace(temp_name, path)

    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def update_zshrc(settings):
    wallpaper_dir = settings.get("wallpaperDir")

    if not wallpaper_dir:
        return

    zshrc = pathlib.Path.home() / ".zshrc"

    if not zshrc.is_file():
        return

    original = zshrc.read_text(encoding="utf-8")

    updated = re.sub(
        r"^export WALLPAPER_DIR=.*$",
        lambda _: (
            "export WALLPAPER_DIR="
            + lua_string(wallpaper_dir)
        ),
        original,
        flags=re.MULTILINE,
    )

    if updated != original:
        atomic_write(zshrc, updated)


def main():
    settings = load_settings()

    # Generate all contents before modifying any config file.
    generated = {
        "keybindings.lua": emit_binds(settings),
        "autostart.lua": emit_autostart(settings),
        "env.lua": emit_env(settings),
        "monitors.lua": emit_monitors(settings),
        "settings.lua": emit_settings(settings),
    }

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    # Keep one backup of the previous generated configuration.
    for name, content in generated.items():
        target = CONFIG_DIR / name

        if target.is_file():
            previous = target.read_text(encoding="utf-8")

            if previous != content:
                shutil.copy2(
                    target,
                    target.with_name(name + ".bak"),
                )

        atomic_write(target, content)

    update_zshrc(settings)

    print("Hyprland Lua configuration generated successfully")

    for name in generated:
        print(f"  {CONFIG_DIR / name}")


if __name__ == "__main__":
    try:
        main()

    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        json.JSONDecodeError,
    ) as error:
        print(f"Configuration generation failed: {error}", file=sys.stderr)
        sys.exit(1)
