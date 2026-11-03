-- Converted from rules.conf: window/layer rule priorities remain unchanged.
for _, rule in ipairs({
    { name = "lr1", match = { namespace = "^(volume_osd)$" }, no_anim = true },
    { name = "lr2", match = { namespace = "^(brightness_osd)$" }, no_anim = true },
    { name = "lr3", match = { namespace = "hyprpicker" }, no_anim = true },
    { name = "lr4", match = { namespace = "qsdock" }, no_anim = true },
    { name = "lr5", match = { namespace = "ext-session-lock" }, blur = true, ignore_alpha = 0.2 },
}) do hl.layer_rule(rule) end

hl.window_rule({ name = "app_launcher", match = { title = "^(app-launcher)$" },
    float = true, center = true, size = {1200, 600}, animation = "slide" })
hl.window_rule({ name = "master_rule", match = { title = "^(qs-master)$" },
    float = true, no_shadow = true, no_initial_focus = true })
