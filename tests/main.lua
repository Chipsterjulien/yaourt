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
    assert_equal(runtime.minimum, "2.24.0")
    assert(runtime.version_at_least("2.24.0"))
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

test("i18n : une seule valeur renvoyée après interpolation", function()
    i18n.set_language("fr")
    assert_equal(select("#", i18n.t("fetch.updating", {
        package = "google-chrome",
    })), 1)
    assert_equal(select("#", i18n.n("summary.failed", 2)), 1)
end)

test("i18n : invites localisées avec un seul choix par défaut", function()
    i18n.set_language("fr")
    assert_equal(
        i18n.prompt("update.continue_manual", true),
        "Continuer la mise à jour ? [O/n/m]"
    )
    assert_equal(
        i18n.prompt("update.continue", false),
        "Continuer la mise à jour ? [O/n]"
    )

    i18n.set_language("en")
    assert_equal(
        i18n.prompt("update.continue_manual", true),
        "Continue the update? [Y/n/m]"
    )

    -- Ces catalogues n'intègrent pas tous eux-mêmes les choix dans la phrase :
    -- le moteur doit les ajouter à partir de leurs réponses localisées.
    i18n.set_language("de")
    assert_equal(
        i18n.prompt("update.continue_manual", true),
        "Weiter mit dem Update? [J/n/m]"
    )
    i18n.set_language("es")
    assert_equal(
        i18n.prompt("update.continue_manual", true),
        "¿Continuar con la actualización? [S/n/m]"
    )

    -- Un ancien catalogue qui place lui-même le bloc reste compatible, mais
    -- le moteur en reprend la structure et retire la fausse majuscule de m.
    i18n.set_language("br")
    assert_equal(
        i18n.prompt("update.continue_manual", true),
        "Kenderc'hel hizivaat ? [Y/n/m]"
    )

    for _, locale in ipairs(i18n.available_languages()) do
        i18n.set_language(locale)
        local prompt = i18n.prompt("update.continue_manual", true)
        local choices = assert(prompt:match("%[([^%]]+)%]"))
        local _, slash_count = choices:gsub("/", "")
        assert_equal(slash_count, 2)
        assert(not prompt:find("/M]", 1, true))
        assert(not prompt:find("\n", 1, true))
        assert_equal(select("#", i18n.prompt("update.continue_manual", true)), 1)
    end

    local original_t = i18n.t
    local ok, err = pcall(function()
        i18n.set_language("fr")
        i18n.t = function(key, variables)
            if key == "update.continue_manual" then
                return "Question externe\nligne injectée [Y/n/M]\t"
            end
            return original_t(key, variables)
        end
        assert_equal(
            i18n.prompt("update.continue_manual", true),
            "Question externe ligne injectée [O/n/m]"
        )
    end)
    i18n.t = original_t
    assert(ok, err)

    assert(i18n.is_answer("m", "manual"))
    assert(i18n.is_answer("M", "manual"))
    i18n.set_language("fr")
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

test("installation : analyse de -Sw et --downloadonly", function()
    local install = require("lib.install")

    for _, args in ipairs({
        { "-Sw", "paquet" },
        { "-S", "--downloadonly", "paquet" },
        { "-S", "-w", "paquet" },
    }) do
        local names, opts = install.parse_opts(args)
        assert_equal(table.concat(names, ","), "paquet")
        assert_equal(opts.download_only, true)
        assert_equal(#opts.passthrough, 0)
    end

    local names, opts = install.parse_opts({
        "-Sfw", "--needed", "--noconfirm", "paquet",
    })
    assert_equal(table.concat(names, ","), "paquet")
    assert_equal(opts.force, true)
    assert_equal(opts.needed, true)
    assert_equal(opts.download_only, true)
    assert_equal(table.concat(opts.passthrough, ","), "--noconfirm")
end)

test("installation : -Sw dépôt délégué sans faux bilan", function()
    local install = require("lib.install")
    local pacman = require("lib.pacman")
    local original_run = util.run
    local original_passthrough = pacman.passthrough
    local calls = {}

    local ok, err = pcall(function()
        util.run = function(argv)
            assert_equal(table.concat(argv, " "), "pacman -Si paquet-depot")
            return { code = 0, stdout = "", stderr = "" }
        end
        pacman.passthrough = function(_, argv)
            calls[#calls + 1] = table.concat(argv, " ")
            return 0
        end

        local code = install.run({ color = false }, { "paquet-depot" }, {
            force = false,
            needed = true,
            download_only = true,
            passthrough = { "--noconfirm" },
        })
        assert_equal(code, 0)
        assert_equal(#calls, 1)
        assert_equal(calls[1], "-S -w --needed --noconfirm paquet-depot")
    end)

    util.run = original_run
    pacman.passthrough = original_passthrough
    assert(ok, err)
end)

test("installation : -Sw refuse globalement toute cible AUR", function()
    local install = require("lib.install")
    local build = require("lib.build")
    local pacman = require("lib.pacman")
    local original_run = util.run
    local original_aur_many = build.aur_many
    local original_passthrough = pacman.passthrough
    local original_error = require("lib.log").error
    local log = require("lib.log")
    local pacman_calls, build_calls, errors = 0, 0, {}

    local ok, err = pcall(function()
        util.run = function(argv)
            local name = argv[3]
            assert_equal(argv[1], "pacman")
            assert_equal(argv[2], "-Si")
            return {
                code = name == "paquet-depot" and 0 or 1,
                stdout = "",
                stderr = "",
            }
        end
        pacman.passthrough = function()
            pacman_calls = pacman_calls + 1
            return 0
        end
        build.aur_many = function()
            build_calls = build_calls + 1
            return {}
        end
        log.error = function(message)
            errors[#errors + 1] = message
        end

        local code = install.run(
            { color = false },
            { "paquet-depot", "paquet-aur" },
            {
                force = false,
                needed = false,
                download_only = true,
                passthrough = {},
            }
        )
        assert_equal(code, 1)
        assert_equal(pacman_calls, 0)
        assert_equal(build_calls, 0)
        assert_equal(#errors, 1)
        assert(errors[1]:find("paquet-aur", 1, true))
        assert(not errors[1]:find("paquet-depot", 1, true))
    end)

    util.run = original_run
    build.aur_many = original_aur_many
    pacman.passthrough = original_passthrough
    log.error = original_error
    assert(ok, err)
end)

test("split packages : plan groupé par pkgbase", function()
    local build = require("lib.build")
    local deps = require("lib.deps")
    local aur = require("lib.aur")
    local original_resolve_many = deps.resolve_many
    local original_info = aur.info

    local ok, err = pcall(function()
        deps.resolve_many = function(_, targets)
            assert_equal(table.concat(targets, ","), "outil,outils-doc")
            return {
                order = { "bibliotheque", "outil", "outils-doc" },
                direct = {
                    bibliotheque = {},
                    outil = { "bibliotheque" },
                    ["outils-doc"] = {},
                },
            }
        end
        aur.info = function(_, names)
            assert_equal(table.concat(names, ","), "bibliotheque,outil,outils-doc")
            return {
                bibliotheque = { Name = "bibliotheque", PackageBase = "bibliotheque" },
                outil = { Name = "outil", PackageBase = "suite-outils" },
                ["outils-doc"] = { Name = "outils-doc", PackageBase = "suite-outils" },
            }
        end

        local plan = assert(build.plan({}, { "outil", "outils-doc" }))
        assert_equal(table.concat(plan.order, ","), "bibliotheque,suite-outils")
        assert_equal(
            table.concat(plan.bases["suite-outils"].packages, ","),
            "outil,outils-doc"
        )
        assert(plan.bases["suite-outils"].explicit.outil)
        assert(plan.bases["suite-outils"].explicit["outils-doc"])
        assert(plan.bases["suite-outils"].dependencies.bibliotheque)
    end)

    deps.resolve_many = original_resolve_many
    aur.info = original_info
    assert(ok, err)
end)

test("split packages : seuls les sous-paquets requis sont installés", function()
    local build = require("lib.build")
    local pacman = require("lib.pacman")
    local original_run = util.run
    local original_exists = babet.fileExists
    local original_passthrough = pacman.passthrough
    local calls = {}
    local paths = {
        ["/tmp/out/outil-1-1-x86_64.pkg.tar.zst"] = "outil",
        ["/tmp/out/outils-doc-1-1-any.pkg.tar.zst"] = "outils-doc",
        ["/tmp/out/outil-debug-1-1-x86_64.pkg.tar.zst"] = "outil-debug",
    }

    local ok, err = pcall(function()
        babet.fileExists = function(path) return paths[path] ~= nil end
        util.run = function(argv, opts)
            if argv[#argv] == "--packagelist" then
                return {
                    code = 0,
                    stdout = table.concat({
                        "/tmp/out/outil-1-1-x86_64.pkg.tar.zst",
                        "/tmp/out/outils-doc-1-1-any.pkg.tar.zst",
                        "/tmp/out/outil-debug-1-1-x86_64.pkg.tar.zst",
                    }, "\n") .. "\n",
                    stderr = "",
                }
            end
            assert_equal(table.concat(argv, " "),
                "pacman -Qp --quiet " .. argv[4])
            assert_equal(opts.env.LC_ALL, "C")
            return { code = 0, stdout = paths[argv[4]] .. "\n", stderr = "" }
        end
        pacman.passthrough = function(_, argv)
            calls[#calls + 1] = table.concat(argv, " ")
            return 0
        end

        local installed, produced = build.install(
            {}, "/tmp/build", { "outil" }, { outil = true }
        )
        assert(installed)
        assert_equal(#produced, 3)
        assert_equal(#calls, 1)
        assert_equal(calls[1], "-U /tmp/out/outil-1-1-x86_64.pkg.tar.zst")
        assert(not calls[1]:find("outils-doc", 1, true))
        assert(not calls[1]:find("outil-debug", 1, true))

        local missing = build.install(
            {}, "/tmp/build", { "outil-absent" }, { ["outil-absent"] = true }
        )
        assert_equal(missing, false)
        assert_equal(#calls, 1)
    end)

    util.run = original_run
    babet.fileExists = original_exists
    pacman.passthrough = original_passthrough
    assert(ok, err)
end)

test("split packages : raisons explicite et dépendance préservées", function()
    local build = require("lib.build")
    local pacman = require("lib.pacman")
    local original_run = util.run
    local original_exists = babet.fileExists
    local original_passthrough = pacman.passthrough
    local calls = {}
    local paths = {
        ["/tmp/out/liboutil-1-1-x86_64.pkg.tar.zst"] = "liboutil",
        ["/tmp/out/outil-1-1-x86_64.pkg.tar.zst"] = "outil",
    }

    local ok, err = pcall(function()
        babet.fileExists = function(path) return paths[path] ~= nil end
        util.run = function(argv, opts)
            if argv[#argv] == "--packagelist" then
                return {
                    code = 0,
                    stdout = table.concat({
                        "/tmp/out/liboutil-1-1-x86_64.pkg.tar.zst",
                        "/tmp/out/outil-1-1-x86_64.pkg.tar.zst",
                    }, "\n") .. "\n",
                    stderr = "",
                }
            end
            assert_equal(table.concat(argv, " "),
                "pacman -Qp --quiet " .. argv[4])
            assert_equal(opts.env.LC_ALL, "C")
            return { code = 0, stdout = paths[argv[4]] .. "\n", stderr = "" }
        end
        pacman.passthrough = function(_, argv)
            calls[#calls + 1] = table.concat(argv, " ")
            return 0
        end

        assert(build.install(
            {},
            "/tmp/build",
            { "liboutil", "outil" },
            { outil = true }
        ))
        assert_equal(#calls, 2)
        assert_equal(calls[1], table.concat({
            "-U --asdeps",
            "/tmp/out/liboutil-1-1-x86_64.pkg.tar.zst",
            "/tmp/out/outil-1-1-x86_64.pkg.tar.zst",
        }, " "))
        assert_equal(calls[2], "-D --asexplicit outil")
    end)

    util.run = original_run
    babet.fileExists = original_exists
    pacman.passthrough = original_passthrough
    assert(ok, err)
end)

test("split packages : erreur d’identification d’un artefact visible", function()
    local build = require("lib.build")
    local pacman = require("lib.pacman")
    local log = require("lib.log")
    local original_run = util.run
    local original_exists = babet.fileExists
    local original_passthrough = pacman.passthrough
    local original_error = log.error
    local errors = {}
    local install_calls = 0
    local path = "/tmp/out/outil-1-1-x86_64.pkg.tar.zst"

    local ok, err = pcall(function()
        babet.fileExists = function(candidate) return candidate == path end
        util.run = function(argv, opts)
            if argv[#argv] == "--packagelist" then
                return { code = 0, stdout = path .. "\n", stderr = "" }
            end
            assert_equal(table.concat(argv, " "),
                "pacman -Qp --quiet " .. path)
            assert_equal(opts.env.LC_ALL, "C")
            return {
                code = 1,
                stdout = "",
                stderr = "error: could not inspect package",
            }
        end
        pacman.passthrough = function()
            install_calls = install_calls + 1
            return 0
        end
        log.error = function(message)
            errors[#errors + 1] = message
        end

        local installed, produced = build.install(
            {}, "/tmp/build", { "outil" }, { outil = true }
        )
        assert_equal(installed, false)
        assert_equal(#produced, 1)
        assert_equal(install_calls, 0)
        assert_equal(#errors, 1)
        assert(errors[1]:find(path, 1, true))
        assert(errors[1]:find("could not inspect package", 1, true))
    end)

    util.run = original_run
    babet.fileExists = original_exists
    pacman.passthrough = original_passthrough
    log.error = original_error
    assert(ok, err)
end)

test("split packages : makepkg ne préinstalle aucun artefact", function()
    local build = require("lib.build")
    local original_passthrough = util.passthrough
    local command

    local ok, err = pcall(function()
        util.passthrough = function(argv)
            command = table.concat(argv, " ")
            return 0
        end
        local made, code = build.make({}, "/tmp/build", false, {
            force = true,
            needed = true,
        })
        assert(made)
        assert_equal(code, 0)
        assert_equal(command, "makepkg -c -f --needed")
        assert(not command:find(" -i", 1, true))
    end)

    util.passthrough = original_passthrough
    assert(ok, err)
end)

test("split packages : un seul build par pkgbase", function()
    local build = require("lib.build")
    local deps = require("lib.deps")
    local original_plan = build.plan
    local original_one_group = build.one_group
    local original_repo_deps = deps.repo_deps_of
    local calls = 0

    local ok, err = pcall(function()
        build.plan = function()
            return {
                order = { "suite-outils" },
                bases = {
                    ["suite-outils"] = {
                        base = "suite-outils",
                        representative = "outil",
                        packages = { "outil", "outils-doc" },
                        explicit = { outil = true, ["outils-doc"] = true },
                        dependencies = {},
                    },
                },
                missing = {},
            }
        end
        deps.repo_deps_of = function() return {} end
        build.one_group = function(_, group)
            calls = calls + 1
            assert_equal(table.concat(group.packages, ","), "outil,outils-doc")
            return {
                build.result("ok", "outil", "ok"),
                build.result("ok", "outils-doc", "ok"),
            }
        end

        local results = build.aur_many({}, { "outil", "outils-doc" })
        assert_equal(calls, 1)
        assert_equal(#results, 2)
        assert(results[1].ok and results[2].ok)
    end)

    build.plan = original_plan
    build.one_group = original_one_group
    deps.repo_deps_of = original_repo_deps
    assert(ok, err)
end)

test("split packages : installation planifiée en une transaction AUR", function()
    local install = require("lib.install")
    local build = require("lib.build")
    local original_run = util.run
    local original_aur_many = build.aur_many
    local calls = 0

    local ok, err = pcall(function()
        util.run = function(argv)
            assert_equal(argv[1], "pacman")
            assert_equal(argv[2], "-Si")
            return { code = 1, stdout = "", stderr = "" }
        end
        build.aur_many = function(_, names)
            calls = calls + 1
            assert_equal(table.concat(names, ","), "outil,outils-doc")
            return {
                build.result("ok", "outil", "ok"),
                build.result("ok", "outils-doc", "ok"),
            }
        end

        assert_equal(install.run(
            { color = false },
            { "outil", "outils-doc" },
            { passthrough = {} }
        ), 0)
        assert_equal(calls, 1)
    end)

    util.run = original_run
    build.aur_many = original_aur_many
    assert(ok, err)
end)

test("split packages : mise à jour planifiée en une transaction AUR", function()
    local update = require("lib.update")
    local build = require("lib.build")
    local original_check = update.check
    local original_display = update.display
    local original_aur_many = build.aur_many
    local original_read = io.read
    local calls = 0

    local ok, err = pcall(function()
        update.check = function()
            local auras = {
                { name = "outil", oldver = "1-1", newver = "2-1" },
                { name = "outils-doc", oldver = "1-1", newver = "2-1" },
            }
            return {}, auras, auras, nil
        end
        update.display = function() end
        io.read = function() return "o" end
        build.aur_many = function(_, names)
            calls = calls + 1
            assert_equal(table.concat(names, ","), "outil,outils-doc")
            return {
                build.result("ok", "outil", "ok"),
                build.result("ok", "outils-doc", "ok"),
            }
        end

        assert_equal(update.run({ color = false, list_aur = false }), 0)
        assert_equal(calls, 1)
    end)

    update.check = original_check
    update.display = original_display
    build.aur_many = original_aur_many
    io.read = original_read
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
        assert_equal(opts.headers["User-Agent"], "yaourt/0.6.0")
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
