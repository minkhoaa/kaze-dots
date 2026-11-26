-- Shared event-driven status widgets. Start/stop-post hooks and kaze-dnd own these signals.
-- Static launchers never execute a status command.
local specs = {
    { "recording", "record", 8, "●", "Stop recording", "kaze-record stop", "danger" },
    { "night", "night", 9, "󰖔", "Turn off Night Light", "kaze-night off", "warn" },
    {
        "dnd",
        nil,
        10,
        "󰂛",
        "Turn off Do Not Disturb (Right-click: Notifications)",
        "kaze-dnd off",
        "accent",
        "if [ -f \\\"${XDG_RUNTIME_DIR:-/nonexistent}/kaze/dnd.state\\\" ]; then echo '󰂛'; fi",
        "kaze-dashboard --notifications",
    },
    { "inhibit", "inhibit", 11, "󰅶", "Turn off Caffeine", "kaze-inhibit off", "accent" },
    {
        "passthrough",
        nil,
        12,
        "󰌌",
        "Exit VM Passthrough (Super+Esc)",
        "hyprctl dispatch \\\"hl.dsp.submap('reset')\\\"",
        "warn",
        "if [ \\\"$(hyprctl submap 2>/dev/null)\\\" = 'passthrough' ]; then echo '󰌌'; fi",
    },
}
local M = { slots = "", config = "" }

for _, spec in ipairs(specs) do
    local name, unit, signal, glyph, tooltip, click, _, custom_exec, click_right = table.unpack(spec)
    local exec_cmd = custom_exec or ("if systemctl --user show -p SubState --value kaze-%s.service | grep -qxE 'running|start-post'; then echo '%s'; fi"):format(unit, glyph)
    local right_line = click_right and string.format(',\n    "on-click-right": "%s"', click_right) or ""
    M.slots = M.slots .. ('    "custom/%s",\n'):format(name)
    M.config = M.config .. ([=[  "custom/%s": {
    "exec": "%s",
    "interval": "once",
    "signal": %d,
    "exec-on-event": false,
    "format": "{text}",
    "align": 0.5,
    "justify": "center",
    "tooltip-format": "%s",
    "on-click": "%s"%s
  },

]=]):format(name, exec_cmd, signal, tooltip, click, right_line)
end

function M.css(vertical)
    local result = "\n#custom-recording,\n#custom-night,\n#custom-dnd,\n#custom-inhibit,\n#custom-passthrough {\n    font-size: 14px;\n"
    result = result .. (vertical and "    min-width: 28px;\n    min-height: 26px;\n    border: 1px solid transparent;\n    margin: 1px 4px;\n    padding: 0;\n" or "    padding: 0 7px;\n") .. "}\n"
    for _, spec in ipairs(specs) do
        result = result .. ("#custom-%s { color: @%s; }\n"):format(spec[1], spec[7])
    end
    return result
end

return M
