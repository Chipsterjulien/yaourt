-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
-- One parser for routing and execution. Unsupported sync combinations fail
-- before classification, refresh, cloning or installation.
local cli = {}
local values = {
    root=true, dbpath=true, sysroot=true, config=true, arch=true,
    ignore=true, ignoregroup=true, cachedir=true, gpgdir=true, hookdir=true,
    logfile=true, overwrite=true, ["print-format"]=true, assumeinstalled=true,
}
local aliases = { sync="S", refresh="y", sysupgrade="u", search="s",
    clean="c", info="i", list="l", downloadonly="w", print="p", quiet="q" }
function cli.parse(args, config)
    local p = { names={}, flags={}, options={}, passthrough={}, refresh=0, upgrade=0,
        force=false, needed=false, noconfirm=false, download_only=false,
        print_only=false, devel=config and config.devel == true or false }
    local function flag(ch)
        p.flags[ch] = (p.flags[ch] or 0) + 1
        if ch == "y" then p.refresh=p.refresh+1 end
        if ch == "u" then p.upgrade=p.upgrade+1 end
        if ch == "w" then p.download_only=true end
        if ch == "p" then p.print_only=true end
        if ch == "f" then p.force=true end
    end
    local i, ended = 1, false
    while i <= #(args or {}) do
        local a = args[i]
        if ended or a:sub(1,1) ~= "-" or a == "-" then
            p.names[#p.names+1]=a
        elseif a == "--" then ended=true
        elseif a:sub(1,2) == "--" then
            local key, value = a:match("^%-%-([^=]+)=(.*)$")
            key = key or a:sub(3)
            if values[key] and value == nil then
                i=i+1; value=args[i]
                if not value then p.error=a end
            end
            p.options[#p.options+1]={key=key,value=value}
            if aliases[key] then flag(aliases[key])
            elseif key == "needed" then p.needed=true
            elseif key == "force" then p.force=true
            elseif key == "noconfirm" then p.noconfirm=true; p.passthrough[#p.passthrough+1]=a
            elseif key == "asdeps" or key == "asexplicit" then
                p.reason=key; p.passthrough[#p.passthrough+1]=a
            elseif key == "devel" then p.devel=true
            elseif key == "no-devel" then p.devel=false end
        else
            for ch in a:sub(2):gmatch(".") do flag(ch) end
        end
        i=i+1
    end
    if not p.flags.S then p.action="native"
    elseif p.flags.i or p.flags.l then p.action="native"
    elseif p.flags.s then p.action="search"
    elseif p.upgrade>0 then p.action="update"
    elseif p.flags.c then p.action=p.flags.c>1 and "full" or "soft"
    elseif p.refresh>0 and #p.names==0 then p.action="native"
    else p.action="install" end
    return p
end
function cli.validate(p)
    if p.action == "native" then return not p.error, p.error end
    if p.error then return false,p.error end
    local allowed = {S=true}
    if p.action == "install" then allowed.f=true; allowed.w=true; allowed.p=true
    elseif p.action == "update" then allowed.y=true; allowed.u=true
    elseif p.action == "search" then allowed.s=true
    else allowed.c=true end
    for ch in pairs(p.flags) do if not allowed[ch] then return false,"-"..ch end end
    for _, o in ipairs(p.options) do
        local permitted = aliases[o.key] and allowed[aliases[o.key]]
        if p.action == "install" or p.action == "update" then
            permitted = permitted or o.key=="needed" or o.key=="noconfirm"
        end
        if p.action == "install" then
            permitted = permitted or o.key=="force" or o.key=="asdeps" or o.key=="asexplicit"
        elseif p.action == "update" then
            permitted = permitted or o.key=="devel" or o.key=="no-devel"
        end
        if not permitted or o.value ~= nil then return false,"--"..o.key end
    end
    if p.action == "update" and #p.names>0 then return false,"-Su <package>" end
    if (p.action=="soft" or p.action=="full") and #p.names>0 then return false,"-Sc <package>" end
    return true
end
return cli
