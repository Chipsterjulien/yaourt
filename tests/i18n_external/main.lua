-- SPDX-License-Identifier: GPL-3.0-or-later

package.path = table.concat({ "./?.lua", "./?/init.lua", package.path }, ";")

local i18n = require("lib.i18n")
i18n.set_language("zz")

assert(i18n.language() == "zz")
local external = i18n.t("update.up_to_date")
assert(external == "EXTERNAL CATALOG OK", "unexpected external value: " .. external)
local english = i18n.t("common.cancelled")
assert(english == "Cancelled.", "unexpected English fallback: " .. english)

i18n.set_language("fr")
external = i18n.t("update.up_to_date")
assert(external == "CATALOGUE EXTERNE OK", "unexpected French override: " .. external)
local french = i18n.t("common.cancelled")
assert(french == "Annulé.", "unexpected French fallback: " .. french)
print("YAOURT_EXTERNAL_I18N_OK")
