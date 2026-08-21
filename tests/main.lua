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
local i18n = require("lib.i18n")
local help = require("lib.help")

-- Les tests historiques verrouillent le vocabulaire français actuel. Les
-- tests i18n dédiés changent explicitement de locale puis la restaurent.
i18n.set_language("fr")

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
    assert_equal(runtime.minimum, "2.22.2")
    assert(runtime.version_at_least("2.22.2"))
    assert(not runtime.version_at_least("999.0.0"))
end)

test("configuration : récapitulatif AUR notable par défaut", function()
    local config = require("lib.config")
    assert_equal(config.defaults().list_aur, "notable")
    assert_equal(config.defaults().language, "auto")
end)

test("i18n : 43 catalogues complets et découvrables", function()
    local expected = {
        "ar", "ast", "bg", "bn", "br", "ca", "cs_CZ", "da", "de", "el",
        "en", "eo", "es", "es_419", "fa", "fi", "fr", "he", "hi", "hu",
        "id", "is", "it", "ja", "ko", "lt", "nb", "nl_NL", "pl", "pt",
        "pt_BR", "ro", "ru", "sk", "sl", "sr", "sv", "th", "tr", "uk",
        "vi", "zh_CN", "zh_TW",
    }
    local available = i18n.available_languages()
    assert_equal(#available, #expected)
    assert_equal(table.concat(available, ","), table.concat(expected, ","))

    for _, locale in ipairs(available) do
        i18n.set_language(locale)
        local translated = i18n.t("update.up_to_date")
        assert(translated ~= "" and translated ~= "update.up_to_date")
        local rendered = i18n.t("config.invalid", { path = "/tmp/config", error = "E" })
        assert(rendered:find("/tmp/config", 1, true))
        assert(rendered:find("E", 1, true))
        assert(not rendered:find("{path}", 1, true))
        assert(not rendered:find("{error}", 1, true))
        local plural = i18n.n("summary.failed", 5)
        assert(plural:find("5", 1, true))
        assert(not plural:find("{count}", 1, true))
    end
    i18n.set_language("fr")
end)

test("i18n : aide structurée et commandes invariantes", function()
    local commands = help.commands()
    local width = 0
    for _, command in ipairs(commands) do
        if #command > width then width = #command end
    end

    for _, locale in ipairs(i18n.available_languages()) do
        i18n.set_language(locale)
        local rendered = help.render("yaourt", "0.0.0-test")
        local lines = {}
        for line in rendered:gmatch("(.-)\n") do
            lines[#lines + 1] = line
        end

        assert_equal(#lines, 3 + #commands)
        assert(lines[1]:find("yaourt", 1, true))
        assert(lines[1]:find("0.0.0-test", 1, true))
        assert_equal(lines[2], "")

        for index, command in ipairs(commands) do
            local line = lines[index + 3]
            assert_equal(line:sub(1, 2), "  ")
            assert_equal(line:sub(3, 2 + #command), command)
            assert_equal(line:sub(width + 3, width + 4), "  ")
            assert(line:sub(width + 5) ~= "")

            local first = assert(rendered:find(command, 1, true))
            assert_equal(rendered:find(command, first + #command, true), nil)
        end
    end
    i18n.set_language("fr")
end)

test("i18n : aide protégée contre un catalogue externe mal formé", function()
    local original_t = i18n.t
    local rendered
    local ok, err = pcall(function()
        i18n.t = function(key, variables)
            if key == "help.search" then
                return "  description externe\nligne injectée\t  "
            end
            return original_t(key, variables)
        end
        rendered = help.render("yaourt", "0.0.0-test")
    end)
    i18n.t = original_t
    assert(ok, err)

    assert(rendered:find(
        "yaourt -Ss <term>           description externe ligne injectée",
        1,
        true
    ))
    assert(not rendered:find("\nligne injectée", 1, true))
end)

test("i18n : normalisation, alias et repli déterministe", function()
    i18n.set_language("pt-BR.UTF-8")
    assert_equal(i18n.language(), "pt_BR")
    assert_equal(table.concat(i18n.fallback_chain(), ","), "pt_BR,pt,en")

    i18n.set_language("cs")
    assert_equal(i18n.language(), "cs_CZ")
    i18n.set_language("zh-Hant")
    assert_equal(i18n.language(), "zh_TW")

    i18n.set_language("xx_YY.UTF-8")
    assert_equal(table.concat(i18n.fallback_chain(), ","), "xx_YY,xx,en")
    assert_equal(i18n.t("update.up_to_date"), "The system is up to date.")
    assert_equal(i18n._normalize("C.UTF-8"), "en")
    assert_equal(i18n._normalize("../../fr"), nil)
    assert_equal(i18n._normalize("fr__FR"), nil)
    i18n.set_language("fr")
end)

test("i18n : règles de pluriel gettext sûres", function()
    local plural = i18n._plural_index
    local arabic = "(n==0) ? 0 : (n==1) ? 1 : (n==2) ? 2 : (n%100>=3 && n%100<=10) ? 3 : (n%100>=11 && n%100<=99) ? 4 : 5"
    assert_equal(plural(arabic, 0), 0)
    assert_equal(plural(arabic, 1), 1)
    assert_equal(plural(arabic, 2), 2)
    assert_equal(plural(arabic, 3), 3)
    assert_equal(plural(arabic, 11), 4)
    assert_equal(plural(arabic, 100), 5)

    local polish = "(n==1) ? 0 : (n%10>=2 && n%10<=4 && (n%100<12 || n%100>14)) ? 1 : 2"
    assert_equal(plural(polish, 1), 0)
    assert_equal(plural(polish, 2), 1)
    assert_equal(plural(polish, 5), 2)
    assert_equal(plural(polish, 12), 2)
    assert_equal(plural(polish, 22), 1)

    local breton = "n%10==1 && n%100!=11 && n%100!=71 && n%100!=91 ? 0 : n%10==2 && n%100!=12 && n%100!=72 && n%100!=92 ? 1 : ((n%10==3 || n%10==4 || n%10==9) && (n%100<10 || n%100>19) && (n%100<70 || n%100>79) && (n%100<90 || n%100>99)) ? 2 : n%1000000==0 && n!=0 ? 3 : 4"
    assert_equal(plural(breton, 1), 0)
    assert_equal(plural(breton, 2), 1)
    assert_equal(plural(breton, 3), 2)
    assert_equal(plural(breton, 1000000), 3)
    assert_equal(plural(breton, 5), 4)
    i18n.set_language("fr")
end)

test("mise à jour : récapitulatif AUR respecté par l'orchestration", function()
    local config = require("lib.config")
    local update = require("lib.update")
    local original_check = update.check
    local original_list_aur = update.list_aur
    local original_display = update.display
    local list_modes, display_calls = {}, 0

    update.check = function()
        return {}, {}, { { name = "yay", in_aur = true } }, nil
    end
    update.list_aur = function(conf, aurall)
        assert_equal(#aurall, 1)
        list_modes[#list_modes + 1] = conf.list_aur
    end
    update.display = function()
        display_calls = display_calls + 1
    end

    local ok, err = pcall(function()
        local conf = config.defaults()
        assert_equal(update.run(conf), 0)
        assert_equal(#list_modes, 1)
        assert_equal(list_modes[1], "notable")
        assert_equal(display_calls, 1)

        conf.list_aur = "all"
        assert_equal(update.run(conf), 0)
        assert_equal(#list_modes, 2)
        assert_equal(list_modes[2], "all")
        assert_equal(display_calls, 2)

        conf.list_aur = true
        assert_equal(update.run(conf), 0)
        assert_equal(#list_modes, 3)
        assert_equal(list_modes[3], true)
        assert_equal(display_calls, 3)

        conf.list_aur = false
        assert_equal(update.run(conf), 0)
        assert_equal(#list_modes, 3)
        assert_equal(display_calls, 4)
    end)

    update.check = original_check
    update.list_aur = original_list_aur
    update.display = original_display
    assert(ok, err)
end)

test("affichage : mode AUR notable", function()
    local config = require("lib.config")
    local update = require("lib.update")
    local original_print = print
    local lines = {}

    local ok, err = pcall(function()
        _G.print = function(...)
            local values = {}
            for i = 1, select("#", ...) do
                values[i] = tostring(select(i, ...))
            end
            lines[#lines + 1] = table.concat(values, "\t")
        end

        local conf = config.defaults()
        conf.color = false
        update.list_aur(conf, {
            {
                name = "paquet-normal",
                oldver = "1.0-1",
                newver = "1.0-1",
                in_aur = true,
            },
            {
                name = "mise-a-jour-simple",
                oldver = "12.0.0-1",
                newver = "12.1.0-1",
                in_aur = true,
                has_update = true,
            },
            {
                name = "paquet-orphelin",
                oldver = "2.0-1",
                newver = "2.0-1",
                in_aur = true,
                orphan = true,
            },
            {
                name = "paquet-perime",
                oldver = "3.0-1",
                newver = "3.0-1",
                in_aur = true,
                outofdate = true,
            },
            {
                name = "paquet-local",
                oldver = "1.0-1",
                in_aur = false,
            },
        })
    end)

    _G.print = original_print
    assert(ok, err)

    local rendered = table.concat(lines, "\n")
    assert(rendered:find("Paquets AUR à surveiller", 1, true))
    assert(rendered:find("paquet-orphelin", 1, true))
    assert(rendered:find("paquet-perime", 1, true))
    assert(rendered:find("Orphelin", 1, true))
    assert(rendered:find("(périmé)", 1, true))
    assert(rendered:find("Paquet non géré par AUR", 1, true))
    assert(rendered:find("paquet-local", 1, true))
    assert(not rendered:find("paquet-normal", 1, true))
    assert(not rendered:find("mise-a-jour-simple", 1, true))
end)

test("affichage : mode AUR complet et alias true", function()
    local config = require("lib.config")
    local update = require("lib.update")

    local function render(mode)
        local original_print = print
        local lines = {}
        local ok, err = pcall(function()
            _G.print = function(...)
                local values = {}
                for i = 1, select("#", ...) do
                    values[i] = tostring(select(i, ...))
                end
                lines[#lines + 1] = table.concat(values, "\t")
            end

            local conf = config.defaults()
            conf.color = false
            conf.list_aur = mode
            update.list_aur(conf, {
                {
                    name = "paquet-normal",
                    oldver = "1.0-1",
                    newver = "1.0-1",
                    in_aur = true,
                },
                {
                    name = "paquet-a-mettre-a-jour",
                    oldver = "2.0-1",
                    newver = "2.1-1",
                    in_aur = true,
                    has_update = true,
                },
            })
        end)
        _G.print = original_print
        assert(ok, err)
        return table.concat(lines, "\n")
    end

    for _, mode in ipairs({ "all", true }) do
        local rendered = render(mode)
        assert(rendered:find("Paquets gérés par AUR", 1, true))
        assert(rendered:find("paquet-normal", 1, true))
        assert(rendered:find("paquet-a-mettre-a-jour", 1, true))
        assert(rendered:find("2.0-1 -> 2.1-1", 1, true))
    end
end)

test("affichage : mode AUR désactivé", function()
    local config = require("lib.config")
    local update = require("lib.update")
    local original_print = print
    local calls = 0
    local ok, err = pcall(function()
        _G.print = function() calls = calls + 1 end
        local conf = config.defaults()
        conf.list_aur = false
        update.list_aur(conf, {
            { name = "paquet-local", in_aur = false },
        })
    end)
    _G.print = original_print
    assert(ok, err)
    assert_equal(calls, 0)
end)

test("affichage : séparation après les paquets AUR notables", function()
    local config = require("lib.config")
    local update = require("lib.update")
    local original_print = print
    local lines = {}
    local ok, err = pcall(function()
        _G.print = function(...)
            local values = {}
            for i = 1, select("#", ...) do
                values[i] = tostring(select(i, ...))
            end
            lines[#lines + 1] = table.concat(values, "\t")
        end

        local conf = config.defaults()
        conf.color = false
        update.list_aur(conf, {
            {
                name = "paquet-orphelin",
                oldver = "1.0-1",
                newver = "1.0-1",
                in_aur = true,
                orphan = true,
            },
        })
    end)
    _G.print = original_print
    assert(ok, err)
    assert(#lines >= 3)
    assert_equal(lines[#lines], "")
end)

test("affichage : mode AUR notable silencieux si tout est sain", function()
    local config = require("lib.config")
    local update = require("lib.update")
    local original_print = print
    local calls = 0
    local ok, err = pcall(function()
        _G.print = function() calls = calls + 1 end
        local conf = config.defaults()
        conf.list_aur = "notable"
        update.list_aur(conf, {
            {
                name = "paquet-sain",
                oldver = "1.0-1",
                newver = "1.0-1",
                in_aur = true,
            },
        })
    end)
    _G.print = original_print
    assert(ok, err)
    assert_equal(calls, 0)
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
        assert_equal(opts.headers["User-Agent"], "yaourt/0.5.0")
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

test("nettoyage complet : suppression récursive des dépôts", function()
    local clean = require("lib.clean")
    local root = "/tmp/yaourt-tests-clean-" .. tostring(babet.pid())
    local pkg = babet.joinPath(root, "paquet", "src")
    if babet.isDir(root) then assert(babet.rmdirAll(root)) end
    assert(babet.mkdir(pkg))

    local file = assert(io.open(babet.joinPath(pkg, "artefact"), "wb"))
    assert(file:write("contenu de test"))
    assert(file:close())

    local original_read = io.read
    local original_passthrough = util.passthrough
    io.read = function() return "o" end
    util.passthrough = function(argv)
        assert_equal(argv[#argv - 1], "pacman")
        assert_equal(argv[#argv], "-Scc")
        return 0
    end

    local call_ok, code = pcall(clean.full, {
        builddir = root,
        color = false,
        sudo = "sudo",
    })
    io.read = original_read
    util.passthrough = original_passthrough

    if not call_ok then
        if babet.isDir(root) then babet.rmdirAll(root) end
        error(code, 0)
    end

    assert_equal(code, 0)
    assert(not babet.isDir(babet.joinPath(root, "paquet")))
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
