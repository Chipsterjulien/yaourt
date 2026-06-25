-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- log.lua — fine couche au-dessus du module `logging` bundlé.
--
-- On garde l'API minimale (info/warn/error/debug) et on applique nos
-- défauts : sortie stderr, couleur pilotée par la config.

local logging = require("logging")

local log = {}

function log.setup(config)
    -- La couleur est opt-in dans logging ; on suit la config.
    logging.set_color(config and config.color == true)
end

function log.debug(...) logging.debug(...) end

function log.info(...) logging.info(...) end

function log.warn(...) logging.warn(...) end

function log.error(...) logging.error(...) end

return log
