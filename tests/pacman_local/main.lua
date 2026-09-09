-- SPDX-License-Identifier: GPL-3.0-or-later
-- The actual cleanup planner queries pacman against a temporary database.
local util = require("lib.util")
local pacman = require("lib.pacman")
local builddeps = require("lib.builddeps")
require("lib.i18n").set_language("en")
local original_run = util.run
local executable = assert(os.getenv("YAOURT_TEST_REAL_PACMAN"))
local config_path = assert(os.getenv("YAOURT_TEST_PACMAN_CONFIG"))
util.run = function(argv, opts)
    assert(argv[1] == "pacman")
    assert(argv[2] == "-Qdtq" or argv[2] == "-Rs")
    local isolated = {executable, "--config", config_path}
    for index = 2, #argv do isolated[#isolated + 1] = argv[index] end
    -- A broken preview must never accept a transaction prompt, even in the
    -- isolated fixture. stdin is not connected to the user's terminal.
    opts = opts or {}; opts.stdin = "n\n"
    return original_run(isolated, opts)
end
pacman.passthrough = function() error("unexpected removal after refusal") end
io.read = function() return "n" end
local result = builddeps.finish({color=false}, {
    mode="ask", before={["old-lib"]=true, ["old-orphan"]=true},
}, {})
assert(result.status == "kept")
assert(table.concat(result.packages, ",") == "new-lib,new-tool")
print("YAOURT_PACMAN_PLAN_OK")
