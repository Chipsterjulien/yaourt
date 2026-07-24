-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- runtime.lua — vérification de la version minimale de Babet.

local version = require("lib.version")

local runtime = {
    minimum = version.babet_min,
}

local function parse_version(text)
    if type(text) ~= "string" then return nil end
    local major, minor, patch = text:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then return nil end
    return tonumber(major), tonumber(minor), tonumber(patch)
end

local function current_version()
    local major = babet.VERSION_MAJOR
    local minor = babet.VERSION_MINOR
    local patch = babet.VERSION_PATCH

    if type(major) == "number"
        and type(minor) == "number"
        and type(patch) == "number"
    then
        return major, minor, patch
    end

    return parse_version(babet.VERSION)
end

function runtime.version_at_least(wanted)
    local major, minor, patch = current_version()
    local wanted_major, wanted_minor, wanted_patch = parse_version(wanted)
    if not major or not wanted_major then return false end

    local current = { major, minor, patch }
    local required = { wanted_major, wanted_minor, wanted_patch }
    for i = 1, 3 do
        if current[i] ~= required[i] then
            return current[i] > required[i]
        end
    end
    return true
end

function runtime.assert_supported()
    if runtime.version_at_least(runtime.minimum) then
        return true
    end

    error(string.format(
        "%s nécessite Babet >= %s (version détectée : %s)",
        version.name,
        runtime.minimum,
        tostring(babet.VERSION or "inconnue")
    ), 0)
end

return runtime
