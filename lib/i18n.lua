-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- i18n.lua — internationalisation centralisée de yaourt.
--
-- Les catalogues intégrés sont générés depuis po/*.po. Les catalogues .mo
-- externes utilisent le domaine "yaourt" et l'arborescence gettext standard :
--   <localedir>/<locale>/LC_MESSAGES/yaourt.mo
--
-- Aucun catalogue externe n'est exécuté comme du code Lua. Les expressions de
-- pluriel gettext sont analysées par le petit interpréteur sûr ci-dessous.

local embedded = require("lib.i18n_catalogs")

local i18n = {}

local state = {
    requested = "auto",
    chain = { "en" },
    external = {},
    plural_cache = {},
}

local function env(name)
    if babet and babet.env then return babet.env(name) end
    return os.getenv(name)
end

local function trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

-- Accepte les formes POSIX (pt_BR.UTF-8@variant) et BCP 47 (pt-BR).
local function normalize(locale)
    locale = trim(locale)
    if locale == "" then return nil end
    locale = locale:gsub("%-", "_")
    locale = locale:gsub("%..*$", "")
    locale = locale:gsub("@.*$", "")
    if locale == "C" or locale == "POSIX" then return "en" end
    if #locale > 64 or locale:find("[^%w_]") or locale:find("__", 1, true)
        or locale:sub(1, 1) == "_" or locale:sub(-1) == "_" then
        return nil
    end

    local parts = {}
    for part in locale:gmatch("[^_]+") do parts[#parts + 1] = part end
    if #parts == 0 then return nil end
    parts[1] = parts[1]:lower()
    for index = 2, #parts do
        if #parts[index] == 2 or #parts[index] == 3 then
            parts[index] = parts[index]:upper()
        elseif #parts[index] == 4 then
            parts[index] = parts[index]:sub(1, 1):upper() .. parts[index]:sub(2):lower()
        end
    end
    return table.concat(parts, "_")
end

local function resolve_alias(locale)
    local aliases = embedded.aliases or {}
    local seen = {}
    while aliases[locale] and not seen[locale] do
        seen[locale] = true
        locale = aliases[locale]
    end
    return locale
end

local function append_locale(chain, seen, locale)
    locale = normalize(locale)
    if not locale then return end

    local candidates = { locale }
    local base = locale:match("^([^_]+)")
    if base and base ~= locale then candidates[#candidates + 1] = base end

    for _, candidate in ipairs(candidates) do
        candidate = resolve_alias(candidate)
        if candidate and not seen[candidate] then
            seen[candidate] = true
            chain[#chain + 1] = candidate
        end
    end
end

local function language_spec(value)
    if value ~= nil and value ~= "" and value ~= "auto" then
        return tostring(value)
    end

    -- LANGUAGE peut contenir une liste de préférences séparées par des ':'.
    for _, name in ipairs({ "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" }) do
        local language = env(name)
        if language and language ~= "" then return language end
    end
    return "en"
end

local function build_chain(value)
    local chain, seen = {}, {}
    local spec = language_spec(value)
    for locale in tostring(spec):gmatch("[^:]+") do
        append_locale(chain, seen, locale)
    end
    append_locale(chain, seen, "en")
    return chain
end

-------------------------------------------------------------------------
-- Analyse sûre des expressions Plural-Forms de GNU gettext
-------------------------------------------------------------------------

local function tokenize(expression)
    local tokens, position = {}, 1
    expression = tostring(expression or "n != 1")
    while position <= #expression do
        local char = expression:sub(position, position)
        if char:match("%s") then
            position = position + 1
        else
            local two = expression:sub(position, position + 1)
            if two == "||" or two == "&&" or two == "==" or two == "~="
                or two == "!=" or two == "<=" or two == ">=" then
                tokens[#tokens + 1] = { kind = "op", value = (two == "~=") and "!=" or two }
                position = position + 2
            elseif char:match("[%?%:%(%)+%-%*/%%!<>]") then
                tokens[#tokens + 1] = { kind = "op", value = char }
                position = position + 1
            elseif char == "n" then
                tokens[#tokens + 1] = { kind = "n", value = char }
                position = position + 1
            else
                local number = expression:sub(position):match("^(%d+)")
                if not number then return nil, "invalid token at byte " .. position end
                tokens[#tokens + 1] = { kind = "number", value = tonumber(number) }
                position = position + #number
            end
        end
    end
    tokens[#tokens + 1] = { kind = "eof", value = "eof" }
    return tokens
end

local function plural_function(expression)
    expression = tostring(expression or "n != 1")
    if state.plural_cache[expression] then return state.plural_cache[expression] end

    local tokens = tokenize(expression)
    if not tokens then
        local fallback = function(n) return n == 1 and 0 or 1 end
        state.plural_cache[expression] = fallback
        return fallback
    end

    local position = 1
    local function peek(value)
        return tokens[position] and tokens[position].value == value
    end
    local function take(value)
        if peek(value) then
            local token = tokens[position]
            position = position + 1
            return token
        end
        return nil
    end
    local function truth(value) return tonumber(value) ~= 0 end
    local function boolean(value) return value and 1 or 0 end

    local parse_conditional

    local function parse_primary()
        local token = tokens[position]
        if token.kind == "number" then
            position = position + 1
            local value = token.value
            return function() return value end
        elseif token.kind == "n" then
            position = position + 1
            return function(n) return n end
        elseif take("(") then
            local inner = parse_conditional()
            if not inner or not take(")") then return nil end
            return inner
        end
        return nil
    end

    local function parse_unary()
        if take("!") then
            local operand = parse_unary()
            if not operand then return nil end
            return function(n) return boolean(not truth(operand(n))) end
        elseif take("-") then
            local operand = parse_unary()
            if not operand then return nil end
            return function(n) return -operand(n) end
        elseif take("+") then
            return parse_unary()
        end
        return parse_primary()
    end

    local function binary(next_level, operators)
        local left = next_level()
        if not left then return nil end
        while operators[tokens[position].value] do
            local operator = tokens[position].value
            position = position + 1
            local right = next_level()
            if not right then return nil end
            local previous = left
            if operator == "+" then left = function(n) return previous(n) + right(n) end
            elseif operator == "-" then left = function(n) return previous(n) - right(n) end
            elseif operator == "*" then left = function(n) return previous(n) * right(n) end
            elseif operator == "/" then left = function(n)
                local divisor = right(n)
                if divisor == 0 then return 0 end
                return math.floor(previous(n) / divisor)
            end
            elseif operator == "%" then left = function(n)
                local divisor = right(n)
                if divisor == 0 then return 0 end
                return previous(n) % divisor
            end
            elseif operator == "==" then left = function(n) return boolean(previous(n) == right(n)) end
            elseif operator == "!=" then left = function(n) return boolean(previous(n) ~= right(n)) end
            elseif operator == "<" then left = function(n) return boolean(previous(n) < right(n)) end
            elseif operator == ">" then left = function(n) return boolean(previous(n) > right(n)) end
            elseif operator == "<=" then left = function(n) return boolean(previous(n) <= right(n)) end
            elseif operator == ">=" then left = function(n) return boolean(previous(n) >= right(n)) end
            elseif operator == "&&" then left = function(n)
                if not truth(previous(n)) then return 0 end
                return boolean(truth(right(n)))
            end
            elseif operator == "||" then left = function(n)
                if truth(previous(n)) then return 1 end
                return boolean(truth(right(n)))
            end
            end
        end
        return left
    end

    local function parse_mul() return binary(parse_unary, { ["*"] = true, ["/"] = true, ["%"] = true }) end
    local function parse_add() return binary(parse_mul, { ["+"] = true, ["-"] = true }) end
    local function parse_rel() return binary(parse_add, { ["<"] = true, [">"] = true, ["<="] = true, [">="] = true }) end
    local function parse_eq() return binary(parse_rel, { ["=="] = true, ["!="] = true }) end
    local function parse_and() return binary(parse_eq, { ["&&"] = true }) end
    local function parse_or() return binary(parse_and, { ["||"] = true }) end

    parse_conditional = function()
        local condition = parse_or()
        if not condition then return nil end
        if take("?") then
            local yes = parse_conditional()
            if not yes or not take(":") then return nil end
            local no = parse_conditional()
            if not no then return nil end
            return function(n)
                if truth(condition(n)) then return yes(n) end
                return no(n)
            end
        end
        return condition
    end

    local evaluator = parse_conditional()
    if not evaluator or tokens[position].kind ~= "eof" then
        evaluator = function(n) return n == 1 and 0 or 1 end
    end

    state.plural_cache[expression] = evaluator
    return evaluator
end

-------------------------------------------------------------------------
-- Lecture bornée des catalogues GNU MO externes
-------------------------------------------------------------------------

local function u32(data, offset, big_endian)
    if offset < 1 or offset + 3 > #data then return nil end
    local a, b, c, d = data:byte(offset, offset + 3)
    if big_endian then return ((a * 256 + b) * 256 + c) * 256 + d end
    return ((d * 256 + c) * 256 + b) * 256 + a
end

local function split_zero(value)
    local values, start = {}, 1
    while true do
        local position = value:find("\0", start, true)
        if not position then
            values[#values + 1] = value:sub(start)
            break
        end
        values[#values + 1] = value:sub(start, position - 1)
        start = position + 1
    end
    return values
end

local function parse_headers(value)
    local headers = {}
    for line in tostring(value or ""):gmatch("[^\n]+") do
        local name, content = line:match("^([^:]+):%s*(.*)$")
        if name then headers[name:lower()] = content end
    end
    return headers
end

local function parse_plural_header(value)
    local nplurals = tonumber(tostring(value or ""):match("nplurals%s*=%s*(%d+)")) or 2
    local expression = tostring(value or ""):match("plural%s*=%s*([^;]+)") or "n != 1"
    if nplurals < 1 or nplurals > 16 then nplurals = 2 end
    return nplurals, trim(expression)
end

local function parse_mo(data)
    if type(data) ~= "string" or #data < 28 or #data > 16 * 1024 * 1024 then return nil end
    local magic_le = u32(data, 1, false)
    local magic_be = u32(data, 1, true)
    local big_endian
    if magic_le == 0x950412de then big_endian = false
    elseif magic_be == 0x950412de then big_endian = true
    else return nil end

    local count = u32(data, 9, big_endian)
    local originals = u32(data, 13, big_endian)
    local translations = u32(data, 17, big_endian)
    if not count or count > 100000 or not originals or not translations then return nil end

    local catalog = { messages = {}, nplurals = 2, plural = "n != 1", answers = {} }
    for index = 0, count - 1 do
        local op = originals + index * 8 + 1
        local tp = translations + index * 8 + 1
        local olen, ooff = u32(data, op, big_endian), u32(data, op + 4, big_endian)
        local tlen, toff = u32(data, tp, big_endian), u32(data, tp + 4, big_endian)
        if not olen or not ooff or not tlen or not toff then return nil end
        if ooff + olen > #data or toff + tlen > #data then return nil end
        local original = data:sub(ooff + 1, ooff + olen)
        local translated = data:sub(toff + 1, toff + tlen)

        if original == "" then
            local headers = parse_headers(translated)
            catalog.nplurals, catalog.plural = parse_plural_header(headers["plural-forms"])
            catalog.answers.yes = headers["x-yaourt-yes"]
            catalog.answers.no = headers["x-yaourt-no"]
            catalog.answers.manual = headers["x-yaourt-manual"]
        else
            local context = original:match("^(.-)\4")
            if context and context ~= "" and translated ~= "" then
                local values = split_zero(translated)
                catalog.messages[context] = (#values == 1) and values[1] or values
            end
        end
    end
    return catalog
end

local function locale_dirs()
    local dirs, seen = {}, {}
    local function add(path)
        path = trim(path)
        if path ~= "" and not seen[path] then
            seen[path] = true
            dirs[#dirs + 1] = path
        end
    end

    local override = env("YAOURT_LOCALEDIR")
    if override then
        for path in override:gmatch("[^:]+") do add(path) end
    end
    local data_home = env("XDG_DATA_HOME")
    if data_home and data_home ~= "" then add(data_home .. "/locale") end
    add("/usr/local/share/locale")
    add("/usr/share/locale")
    return dirs
end

local function external_catalog(locale)
    for _, dir in ipairs(locale_dirs()) do
        local path = dir .. "/" .. locale .. "/LC_MESSAGES/yaourt.mo"
        local file = io.open(path, "rb")
        if file then
            local data = file:read("a")
            file:close()
            local catalog = parse_mo(data)
            if catalog then return catalog end
        end
    end
    return nil
end

-------------------------------------------------------------------------
-- API publique
-------------------------------------------------------------------------

function i18n.set_language(value)
    state.requested = value or "auto"
    state.chain = build_chain(value)
    state.external = {}
    for _, locale in ipairs(state.chain) do
        state.external[locale] = external_catalog(locale) or false
    end
    return state.chain[1]
end

function i18n.configure(config)
    return i18n.set_language(config and config.language or "auto")
end

function i18n.language()
    return state.chain[1] or "en"
end

function i18n.fallback_chain()
    local result = {}
    for index, locale in ipairs(state.chain) do result[index] = locale end
    return result
end

function i18n.available_languages()
    local result = {}
    for locale in pairs(embedded.catalogs or {}) do result[#result + 1] = locale end
    table.sort(result)
    return result
end

local function lookup(key)
    for _, locale in ipairs(state.chain) do
        local external = state.external[locale]
        if external then
            local value = external.messages and external.messages[key]
            if value ~= nil and value ~= "" then return value, external end
        end

        local builtin = (embedded.catalogs or {})[locale]
        local value = builtin and builtin.messages and builtin.messages[key]
        if value ~= nil and value ~= "" then return value, builtin end
    end
    return key, nil
end

local function interpolate(value, variables)
    value = tostring(value or "")
    if not variables then return value end
    local marker = "\1YAOURT_OPEN_BRACE\2"
    value = value:gsub("{{", marker)
    value = value:gsub("{([%w_.-]+)}", function(name)
        local replacement = variables[name]
        if replacement == nil then return "{" .. name .. "}" end
        return tostring(replacement)
    end)
    -- string.gsub renvoie aussi le nombre de substitutions. Stocker le texte
    -- avant de le retourner garantit que i18n.t/i18n.n n'exposent jamais cette
    -- seconde valeur aux fonctions variadiques telles que log.info ou print.
    value = value:gsub(marker, "{")
    return value
end

function i18n.t(key, variables)
    local value = lookup(key)
    if type(value) == "table" then value = value[1] end
    return interpolate(value, variables)
end

function i18n.n(key, count, variables)
    local value, catalog = lookup(key)
    variables = variables or {}
    if variables.count == nil then variables.count = count end
    if type(value) == "table" then
        local evaluator = plural_function(catalog and catalog.plural or "n != 1")
        local index = math.floor(tonumber(evaluator(tonumber(count) or 0)) or 0)
        local maximum = (catalog and catalog.nplurals or #value) - 1
        if index < 0 then index = 0 elseif index > maximum then index = maximum end
        value = value[index + 1] or value[#value] or value[1]
    end
    return interpolate(value, variables)
end

local universal_answers = {
    yes = { y = true, yes = true, o = true, oui = true },
    no = { n = true, no = true, non = true },
    manual = { m = true, manual = true, manuel = true },
}

function i18n.is_answer(value, kind)
    value = trim(value):lower()
    if universal_answers[kind] and universal_answers[kind][value] then return true end

    local function matches(catalog)
        local answers = catalog and catalog.answers and catalog.answers[kind]
        if type(answers) == "string" then
            for answer in answers:gmatch("[^,]+") do
                if trim(answer):lower() == value then return true end
            end
        end
        return false
    end

    for _, locale in ipairs(state.chain) do
        if matches(state.external[locale]) then return true end
        if matches((embedded.catalogs or {})[locale]) then return true end
    end
    return false
end

-- Langue initiale pour les erreurs qui précèdent le chargement de la config.
i18n.set_language("auto")

-- Exposé uniquement pour les tests du parseur, sans accepter de code arbitraire.
i18n._plural_index = function(expression, n)
    return plural_function(expression)(n)
end
i18n._parse_mo = parse_mo
i18n._normalize = normalize

return i18n
