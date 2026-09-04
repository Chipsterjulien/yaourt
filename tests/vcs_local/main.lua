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
local vcs = require("lib.vcs")

assert(runtime.assert_supported())

local repository = assert(babet.env("YAOURT_TEST_VCS_REPOSITORY"))
local revision, err = vcs.query({
    kind = "git",
    url = repository,
    ref = "HEAD",
    allow_local = true,
})
assert(revision, err)
assert(revision:match("^%x+$"))
print("YAOURT_VCS_REVISION=" .. revision)
