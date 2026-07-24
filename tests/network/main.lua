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

local config = {
    aur_url = "https://aur.archlinux.org",
}

local info, info_err = aur.info(config, { "yay" })
assert(info, info_err)
assert(info.yay and info.yay.Name == "yay")
print("[PASS] AUR RPC info")

local results, search_err = aur.search(config, "yay", "name")
assert(results, search_err)
assert(type(results) == "table" and #results > 0)
print("[PASS] AUR RPC search")

print("=== 2 tests réseau PASS / 0 FAIL ===")
