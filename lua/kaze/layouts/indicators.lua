-- Shared event-driven status widgets. Start/stop-post hooks own these signals;
-- reserve +10 for notification DND. Static launchers never execute a status command.
local specs = {
    { "recording", "record", 8, "●", "Stop recording", "kaze-record stop", "danger" },
    { "night", "night", 9, "󰖔", "Turn off Night Light", "kaze-night off", "warn" },
    { "inhibit", "inhibit", 11, "󰅶", "Turn off Caffeine", "kaze-inhibit off", "accent" },
}
local M = { slots = "", config = "" }

for _, spec in ipairs(specs) do
    local name, unit, signal, glyph, tooltip, click = table.unpack(spec)
    M.slots = M.slots .. ('    "custom/%s",\n'):format(name)
    M.config = M.config .. ([=[  "custom/%s": {
    "exec": "if systemctl --user show -p SubState --value kaze-%s.service | grep -qxE 'running|start-post'; then echo '%s'; fi",
    "interval": "once",
    "signal": %d,
    "exec-on-event": false,
    "format": "{text}",
    "align": 0.5,
    "justify": "center",
    "tooltip-format": "%s",
    "on-click": "%s"
  },

]=]):format(name, unit, glyph, signal, tooltip, click)
end

function M.css(vertical)
    local result = "\n#custom-recording,\n#custom-night,\n#custom-inhibit {\n    font-size: 14px;\n"
    result = result .. (vertical and "    min-width: 32px;\n    min-height: 26px;\n    margin: 0 4px;\n    padding: 0;\n" or "    padding: 0 7px;\n") .. "}\n"
    for _, spec in ipairs(specs) do
        result = result .. ("#custom-%s { color: @%s; }\n"):format(spec[1], spec[7])
    end
    return result
end

return M
