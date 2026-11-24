local M = {}

local ORDER = { "noctalia" }

local REGISTRY = {
    noctalia = "omarch.layouts.noctalia",
}

local REQUIRED_HYPR = { "gaps_in", "gaps_out", "rounding", "border_size" }
local REQUIRED_UI = {
    "fuzzel_radius",
    "fnott_radius",
    "fnott_anchor",
    "fnott_edge_margin_vertical",
    "fnott_edge_margin_horizontal",
}

function M.list()
    local out = {}
    for i, name in ipairs(ORDER) do
        out[i] = name
    end
    return out
end

function M.validate(spec)
    assert(type(spec) == "table", "layout spec must be a table")
    assert(type(spec.name) == "string" and spec.name ~= "", "layout.name must be a non-empty string")
    assert(type(spec.label) == "string" and spec.label ~= "", "layout.label must be a non-empty string")
    assert(type(spec.hypr) == "table", "layout.hypr must be a table")
    for _, k in ipairs(REQUIRED_HYPR) do
        assert(type(spec.hypr[k]) == "number", "layout.hypr." .. k .. " must be a number")
    end
    assert(type(spec.ui) == "table", "layout.ui must be a table")
    for _, k in ipairs(REQUIRED_UI) do
        assert(spec.ui[k] ~= nil, "layout.ui." .. k .. " is required")
    end
    assert(type(spec.build_waybar_config) == "function", "layout.build_waybar_config must be a function")
    assert(type(spec.build_waybar_css) == "function", "layout.build_waybar_css must be a function")
    return spec
end

function M.get(name)
    local mod_name = REGISTRY[name]
    if not mod_name then
        error(string.format("unknown layout '%s' (available: %s)", tostring(name), table.concat(ORDER, ", ")))
    end
    local spec = require(mod_name)
    return M.validate(spec)
end

return M
