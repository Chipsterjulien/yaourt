-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth

-- Mode dossier depuis la racine : ./?.lua
-- Mode dossier lancé depuis tests/ : ../?.lua
-- Mode embarqué de test : ./?.lua
package.path = table.concat({
    "./?.lua",
    "./?/init.lua",
    "../?.lua",
    "../?/init.lua",
    package.path,
}, ";")

local runtime = require("lib.runtime")
local util = require("lib.util")

local passed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        io.stderr:write("[FAIL] ", name, " : ", tostring(err), "\n")
        os.exit(1)
    end
    passed = passed + 1
    print("[PASS] " .. name)
end

local function assert_equal(actual, expected)
    if actual ~= expected then
        error(string.format(
            "valeur attendue %q, valeur obtenue %q",
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

test("runtime Babet supporté", function()
    assert(runtime.assert_supported())
    assert(runtime.version_at_least("2.9.0"))
    assert(not runtime.version_at_least("999.0.0"))
end)

test("surface Babet utilisée par yaourt", function()
    local required = {
        ["babet.env"] = babet.env,
        ["babet.exec"] = babet.exec,
        ["babet.spawn"] = babet.spawn,
        ["babet.mkdir"] = babet.mkdir,
        ["babet.joinPath"] = babet.joinPath,
        ["babet.isDir"] = babet.isDir,
        ["babet.rmdirAll"] = babet.rmdirAll,
        ["babet.find"] = babet.find,
        ["babet.fileExists"] = babet.fileExists,
        ["babet.remove"] = babet.remove,
        ["babet.split"] = babet.split,
        ["babet.mergeTables"] = babet.mergeTables,
        ["babet.which"] = babet.which,
        ["babet.http.get"] = babet.http.get,
        ["babet.sleep"] = babet.sleep,
        ["babet.json.decode"] = babet.json.decode,
        ["babet.toml.decode"] = babet.toml.decode,
        ["babet.user.get"] = babet.user.get,
        ["babet.user.exists"] = babet.user.exists,
    }

    for name, fn in pairs(required) do
        assert(type(fn) == "function", name .. " indisponible")
    end
    assert(babet.json.null ~= nil, "babet.json.null indisponible")
end)

test("exec sans shell et arguments préservés", function()
    local value = "argument avec espaces et ' apostrophe"
    local result, err = util.run({
        "sh", "-c", "printf '%s' \"$1\"", "sh", value,
    })
    assert(result, err)
    assert_equal(result.code, 0)
    assert_equal(result.stdout, value)
    assert_equal(result.stderr, "")
    assert_equal(result.timed_out, false)
end)

test("client AUR : contrats HTTP et JSON", function()
    local aur = require("lib.aur")
    local original_get = babet.http.get
    local original_sleep = babet.sleep
    local info_calls, sleep_calls = 0, 0

    babet.http.get = function(url, opts)
        assert_equal(opts.headers.Accept, "application/json")
        assert_equal(opts.headers["User-Agent"], "yaourt/0.4.1")
        assert_equal(opts.timeout, 15)

        if url:find("/info?", 1, true) then
            info_calls = info_calls + 1
            assert_equal(url,
                "https://aur.example/rpc/v5/info?arg%5B%5D=yay")
            assert_equal(opts.query, nil)
            if info_calls == 1 then
                return nil, "http: Failed to read connection"
            end
            return {
                status = 200,
                body = [[
                    {"type":"multiinfo","resultcount":1,
                     "results":[{"Name":"yay","Version":"12.0.0"}]}
                ]],
            }
        end

        assert_equal(url, "https://aur.example/rpc/v5/search/yay")
        assert_equal(opts.query.by, "name")
        return {
            status = 200,
            body = [[
                {"type":"search","resultcount":1,
                 "results":[{"Name":"yay","Version":"12.0.0"}]}
            ]],
        }
    end

    babet.sleep = function(amount, unit)
        assert_equal(amount, 250)
        assert_equal(unit, "ms")
        sleep_calls = sleep_calls + 1
        return true
    end

    local info, info_err = aur.info({ aur_url = "https://aur.example" }, {
        "yay",
    })
    assert(info, info_err)
    assert_equal(info.yay.Version, "12.0.0")
    assert_equal(info_calls, 2)
    assert_equal(sleep_calls, 1)

    local results, search_err = aur.search(
        { aur_url = "https://aur.example" },
        "yay",
        "name"
    )
    assert(results, search_err)
    assert_equal(#results, 1)
    assert_equal(results[1].Name, "yay")

    babet.http.get = original_get
    babet.sleep = original_sleep
end)

test("échec AUR : aucun faux paquet non géré", function()
    local aur = require("lib.aur")
    local update = require("lib.update")
    local original_info = aur.info
    local original_run = util.run
    local original_passthrough = util.passthrough

    util.passthrough = function(argv)
        assert_equal(table.concat(argv, " "), "pacman -Sy")
        return 0
    end

    util.run = function(argv)
        local command = table.concat(argv, " ")
        if command == "id -u" then
            return { code = 0, stdout = "0\n", stderr = "" }
        end
        if command == "pacman -Qu" then
            return { code = 1, stdout = "", stderr = "" }
        end
        if command == "pacman -Qm" then
            return {
                code = 0,
                stdout = "yay 12.0.0-1\npaquet-local 1.0-1\n",
                stderr = "",
            }
        end
        error("commande inattendue : " .. command)
    end

    aur.info = function()
        return nil, "aur: http: Failed to read connection"
    end

    local repos, auras, aurall, aurerr = update.check({
        sudo = "sudo",
    })
    assert_equal(#repos, 0)
    assert_equal(#auras, 0)
    assert_equal(#aurall, 0)
    assert_equal(aurerr, "aur: http: Failed to read connection")

    aur.info = original_info
    util.run = original_run
    util.passthrough = original_passthrough
end)

test("mkdir natif récursif et idempotent", function()
    local root = "/tmp/yaourt-tests-" .. tostring(babet.pid())
    if babet.isDir(root) then assert(babet.rmdirAll(root)) end

    local nested = babet.joinPath(root, "a", "b")
    assert(util.mkdirp(nested))
    assert(util.mkdirp(nested))
    assert(babet.isDir(nested))
    assert(babet.rmdirAll(root))
end)

test("spawn interactif : code de sortie", function()
    local code, err = util.passthrough({ "sh", "-c", "exit 7" })
    assert_equal(err, nil)
    assert_equal(code, 7)
end)

test("spawn interactif : arguments sans quoting shell", function()
    local value = "argument avec espaces et ' apostrophe"
    local code, err = util.passthrough({ "test", value, "=", value })
    assert_equal(err, nil)
    assert_equal(code, 0)
end)

test("spawn interactif : répertoire de travail", function()
    local root = "/tmp/yaourt-tests-cwd-" .. tostring(babet.pid())
    if babet.isDir(root) then assert(babet.rmdirAll(root)) end
    assert(babet.mkdir(root))

    local code, err = util.passthrough({
        "sh", "-c", "test \"$PWD\" = \"$1\"", "sh", root,
    }, root)
    assert_equal(err, nil)
    assert_equal(code, 0)
    assert(babet.rmdirAll(root))
end)

test("spawn interactif : convention des signaux", function()
    local code, err = util.passthrough({ "sh", "-c", "kill -INT \"$$\"" })
    assert_equal(err, nil)
    assert_equal(code, 130)
    assert(util.is_interrupted(code))
    assert(not util.is_interrupted(143))
end)

test("spawn interactif : échec de lancement", function()
    local code, err = util.passthrough({
        "commande-yaourt-qui-n-existe-certainement-pas",
    })
    assert_equal(code, 1)
    assert(type(err) == "string" and err ~= "")
end)

print(string.format("=== %d test(s) PASS / 0 FAIL ===", passed))
