-- Hyprland 0.57 Lua entry point. Original dotfiles migrated without changing Quickshell.
-- Do not add `source = ...conf`: Hyprland no longer parses these files.
-- The passthru submap is used by the Quickshell shortcut editor.
hl.define_submap("passthru", function()
    hl.bind("SUPER + SHIFT + CTRL + ALT + F35", hl.dsp.exec_cmd("true"))
end)
require("config.monitors")
require("config.env")
require("config.autostart")
require("config.settings")
require("config.rules")
require("config.keybindings")
