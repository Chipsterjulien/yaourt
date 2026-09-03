-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth

package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "../?.lua",
    "../?/init.lua",
    "../../?.lua",
    "../../?/init.lua",
    package.path,
}, ";")

local runtime = require("lib.runtime")
local aur = require("lib.aur")

assert(runtime.assert_supported())

local aur_url = assert(
    babet.env("YAOURT_TEST_AUR_URL"),
    "YAOURT_TEST_AUR_URL absent"
)
local config = { aur_url = aur_url }

local info, info_err = aur.info(config, { "yay" })
assert(info, info_err)
assert(info.yay and info.yay.Name == "yay")
assert(info.yay.Version == "12.0.0")

local results, search_err = aur.search(config, "yay", "name")
assert(results, search_err)
assert(#results == 1)
assert(results[1].Name == "yay")
assert(results[1].Version == "12.0.0")

local providers, providers_err = aur.providers(config, "virtual-tool")
assert(providers, providers_err)
assert(#providers == 1)
assert(providers[1].Name == "tool-provider")
assert(providers[1].Version == "2.0.0")
assert(providers[1].Provides[1] == "virtual-tool=2")

print("YAOURT_LOCAL_AUR_OK")
