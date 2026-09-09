-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
-- Approval belongs to the invoking user, never to the build account.
-- A successful pull or an existing checkout is not an approval.
local util = require("lib.util")
local i18n = require("lib.i18n")
local color = require("lib.color")
local review = {}

local function digest(data)
    local res, err = util.run({"sha256sum", "-"}, {stdin=data})
    if not util.complete(res) then return nil, err or (res and res.stderr), res and res.code end
    return res.stdout:match("^(%x+)")
end
local function storage(config)
    local root = util.is_root()
    local dir = config._review_state_dir or (root and "/var/lib/yaourt-reviews"
        or ((babet.env("XDG_STATE_HOME") or (util.home() .. "/.local/state")) .. "/yaourt/reviews"))
    local made, err = util.run({"mkdir", "-p", "-m", "700", "--", dir})
    if not util.complete(made) then return nil, err or (made and made.stderr) end
    -- stat does not dereference the final symlink. Refuse inherited writable
    -- or foreign directories instead of trying to fix their ownership.
    local stat = util.run({"stat", "-c", "%u %a %F", "--", dir}, {env={LC_ALL="C"}})
    local uid = util.run({"id", "-u"})
    if not util.complete(stat) or not util.complete(uid) then return nil, "stat: " .. dir end
    local owner, mode, kind = stat.stdout:match("^(%d+) (%d+) ([^\n]+)")
    if owner ~= uid.stdout:match("%d+") or mode ~= "700" or kind ~= "directory" then
        return nil, "permissions: " .. dir
    end
    return dir
end
local function git(config, dest, args)
    local argv = {"git", "-C", dest}
    for _, value in ipairs(args) do argv[#argv+1]=value end
    local res, err = util.run_as(config.build_user, argv, {env={LC_ALL="C"}})
    if not util.complete(res) then return nil, err or (res and res.stderr) or "git", res and res.code or 1 end
    return res.stdout
end
function review.snapshot(config, dest)
    local listed, err, code = git(config, dest, {"ls-files", "--stage", "-z"})
    if not listed then return nil, err, code end
    local files, rows, seen = {}, {}, {}
    for item in listed:gmatch("([^%z]+)%z") do
        local mode, stage, path = item:match("^(%d+) %x+ (%d)\t(.+)$")
        -- Symlinks/submodules and unresolved index entries cannot be displayed
        -- and hashed as ordinary build inputs. Fail closed.
        if not path or stage ~= "0" or (mode~="100644" and mode~="100755")
                or path:find("[%c]") or path:sub(1,1)=="/" or path:match("^%.%./")
                or path:find("/../",1,true) or seen[path] then
            return nil, "git ls-files: " .. tostring(path or item), 1
        end
        seen[path]=true
        files[#files+1]=path
    end
    if not seen.PKGBUILD then return nil, "PKGBUILD", 1 end
    table.sort(files, function(a,b) if a=="PKGBUILD" then return true end; if b=="PKGBUILD" then return false end; return a<b end)
    for _, path in ipairs(files) do
        -- Refuse a tracked regular file replaced locally with a symlink.
        local stat = util.run_as(config.build_user, {"stat", "-c", "%F %a", "--", dest.."/"..path}, {env={LC_ALL="C"}})
        if not util.complete(stat) or not stat.stdout:match("^regular .*file %d+") then
            return nil, "stat: " .. path, stat and stat.code or 1
        end
        local hashed = util.run_as(config.build_user, {"sha256sum", "--", dest.."/"..path})
        if not util.complete(hashed) then return nil, "sha256sum: "..path, hashed and hashed.code or 1 end
        local hash=hashed.stdout:match("^(%x+)")
        if not hash or #hash~=64 then return nil, "sha256sum: "..path, 1 end
        rows[#rows+1]=path.."\t"..stat.stdout:gsub("\n$", "").."\t"..hash
    end
    local head, herr, hcode = git(config, dest, {"rev-parse", "--verify", "HEAD"})
    if not head then return nil,herr,hcode end
    head=head:match("^(%x+)\n$")
    if not head then return nil,"git rev-parse",1 end
    local dirty, derr, dcode = git(config,dest,{"status","--porcelain","--untracked-files=no"})
    if not dirty then return nil,derr,dcode end
    local hash, hasherr, hashcode=digest(table.concat(rows,"\n"))
    if not hash then return nil,hasherr,hashcode end
    return {files=files, hash=hash, head=head, clean=dirty==""}
end
function review.run(config, meta)
    local dest, C = meta.path, color.new(config.color)
    local dir, storage_err=storage(config)
    if not dir then return false, storage_err, 1 end
    local key, keyerr=digest(dest)
    if not key then return false,keyerr,1 end
    local path=dir.."/"..key
    local current, err, code=review.snapshot(config,dest)
    if not current then return false,err,code end
    local approved
    local file=io.open(path,"rb")
    if file then
        local body=file:read("a"); file:close()
        if body then
            local head,hash,clean=body:match("^YAOURT%-REVIEW%-1\n(%x+)\n(%x+)\n([01])\n$")
            if head then approved={head=head,hash=hash,clean=clean=="1"} end
        end
    end
    if approved and approved.hash==current.hash then
        print(C.dim("==> "..i18n.t("review.unchanged")))
        return true
    end
    local diff_review = approved and approved.clean and current.clean
    if diff_review then
        local diff, derr, dcode=git(config,dest,{"diff","--no-ext-diff","--no-textconv","--color=always",approved.head,"--"})
        if not diff then return false,derr,dcode end
        if diff=="" then return false,"git diff: empty",1 end
        print(C.cyan("==> ")..i18n.t("review.changes")); io.write(diff)
    else
        print(C.cyan("==> ")..i18n.n("review.files",#current.files))
        for index,name in ipairs(current.files) do
            print("  ["..index.."/"..#current.files.."] "..name)
            local argv={config.editor, dest.."/"..name}
            if config.build_user then
                -- The build account has no access to the caller's desktop.
                -- Even terminal Vim can probe X11 for clipboard support.
                -- Unset these variables AFTER runuser/PAM, retaining the
                -- terminal and locale. Never grant access to the desktop.
                argv=babet.mergeTables({"runuser","-u",config.build_user,"--",
                    "env","-u","DISPLAY","-u","WAYLAND_DISPLAY",
                    "-u","XAUTHORITY","-u","DBUS_SESSION_BUS_ADDRESS",
                    "-u","SESSION_MANAGER","-u","XDG_RUNTIME_DIR","--"},argv)
            end
            local editor_code=util.passthrough(argv)
            if editor_code~=0 then
                return false,i18n.t("review.open_failed",{file=name,editor=config.editor}),editor_code
            end
        end
    end
    -- Editors may change the files deliberately. Include those changes, but
    -- never approve a newly added file that was not presented above.
    local after, aerr, acode=review.snapshot(config,dest)
    if not after then return false,aerr,acode end
    if diff_review and after.hash ~= current.hash then return false,"review: changed during diff",1 end
    if table.concat(after.files,"\0")~=table.concat(current.files,"\0") then return false,"git ls-files: changed",1 end
    io.write(i18n.t("review.continue").." "); io.flush()
    local answer=io.read("l")
    if answer==nil or (answer~="" and not i18n.is_answer(answer:lower(),"yes")) then return false,"refused",1 end
    -- mktemp in the private directory prevents symlink clobbering; rename
    -- replaces the previous record only after successful explicit approval.
    local tmp, terr=util.run({"mktemp", "--", path..".XXXXXX"})
    if not util.complete(tmp) then return false,terr or "mktemp",1 end
    local temp=tmp.stdout:gsub("\n$", "")
    local out,oerr=io.open(temp,"wb")
    if not out then babet.remove(temp); return false,oerr,1 end
    local written,werr=out:write("YAOURT-REVIEW-1\n",after.head,"\n",after.hash,"\n",after.clean and "1\n" or "0\n")
    local closed,cerr=out:close()
    if not written or not closed then babet.remove(temp);return false,werr or cerr,1 end
    local saved,serr=os.rename(temp,path)
    if not saved then babet.remove(temp);return false,serr,1 end
    return true
end
return review
