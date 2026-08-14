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
local util = require("lib.util")

assert(runtime.assert_supported())

io.write("YAOURT_PARENT_PROMPT\n")
io.flush()
assert(io.read("l") == "parent", "réponse parent inattendue")

local code, err = util.passthrough({
    "sh",
    "-c",
    [[
        printf '%s\n' YAOURT_CHILD_PROMPT
        IFS= read -r answer
        test "$answer" = child
    ]],
})

assert(code == 0, err or ("code enfant inattendu : " .. tostring(code)))
print("YAOURT_INTERACTIVE_OK")
