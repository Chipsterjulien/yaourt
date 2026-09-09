-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
-- Audit regressions: real orchestration, mocked package-manager boundaries.
return function(test, equal)
local util=require("lib.util")
local cli=require("lib.cli")
local aur=require("lib.aur")
local build=require("lib.build")
local builddeps=require("lib.builddeps")
local deps=require("lib.deps")
local install=require("lib.install")
local update=require("lib.update")
local pacman=require("lib.pacman")
local vcs=require("lib.vcs")
local function res(code,stdout,stderr) return {code=code or 0,stdout=stdout or "",stderr=stderr or ""} end
local function scenario(name,fn)
    test(name,function()
        local saved={}
        local function patch(object,key,value)
            saved[#saved+1]={object,key,object[key]};object[key]=value
        end
        local ok,err=pcall(fn,patch)
        for n=#saved,1,-1 do local p=saved[n];p[1][p[2]]=p[3] end
        aur.clear_cache()
        assert(ok,err)
    end)
end
scenario("options : variantes courtes, longues et valeurs séparées",function()
    for _, args in ipairs({{"-Sw","demo"},{"-wS","demo"},{"-S","-w","demo"},{"--sync","--downloadonly","demo"}}) do
        local p=cli.parse(args);assert(cli.validate(p));assert(p.download_only);equal(p.names[1],"demo")
    end
    local p=cli.parse({"--ignore","keep-me","-S","demo"})
    equal(#p.names,1);equal(p.names[1],"demo");equal(p.options[1].value,"keep-me");assert(not cli.validate(p))
    equal(cli.parse({"-Su"}).refresh,0)
    p=cli.parse({"-Syyuu"});equal(p.refresh,2);equal(p.upgrade,2)
end)
scenario("options : refus des combinaisons qui changent silencieusement l'opération",function()
    for _,args in ipairs({{"-Syu","--downloadonly"},{"-Syuw"},{"-Syu","--root=/guest"},
        {"-S","--root","/guest","demo"},{"-Syu","--ignore=demo"},{"-Syu","--config","/tmp/pacman.conf"},
        {"-Sy","demo"},{"-Syu","demo"},{"-S","--overwrite=*","demo"}}) do
        assert(not cli.validate(cli.parse(args)),table.concat(args," "))
    end
end)
scenario("options : -Sp AUR refuse sans compilation ni transaction",function(patch)
    patch(util,"run",function() return res(1) end)
    patch(build,"aur_many",function() error("unexpected build") end)
    patch(pacman,"passthrough",function() error("unexpected transaction") end)
    equal(install.run({color=false},{"demo"},cli.parse({"-Sp","demo"})),1)
end)
for _,code in ipairs({1,130,143}) do
    scenario("interruption : synchronisation échouée ("..code..") arrête toute collecte",function(patch)
        patch(util,"sudo_prefix",function() return nil end)
        patch(util,"passthrough",function() return code end)
        patch(util,"run",function() error("query after failed refresh") end)
        patch(build,"aur_many",function() error("build after failed refresh") end)
        equal(update.run({color=false},{refresh=1}),code)
    end)
end
scenario("mise à jour : remplacement seul pris en compte et -Su sans -Sy",function(patch)
    local called={}
    patch(util,"sudo_prefix",function() return nil end)
    patch(util,"run",function(argv)
        if argv[2]=="-Sup" then return res(0,"extra\treplacement\t2-1\n") end
        if argv[2]=="-Q" then return res(0,"old-name 1-1\n") end
        if argv[2]=="-Qm" then return res(1) end
        error(table.concat(argv," "))
    end)
    patch(util,"passthrough",function(argv) called[#called+1]=table.concat(argv," ");return 0 end)
    patch(io,"read",function() return "o" end)
    equal(update.run({color=false},cli.parse({"-Su"})),0)
    equal(#called,1);equal(called[1],"pacman -Su")
end)
scenario("mise à jour : répétitions yy/uu et --needed/--noconfirm conservés",function(patch)
    local called={}
    patch(util,"sudo_prefix",function() return nil end)
    patch(util,"run",function(argv)
        if argv[2]=="-Suup" then assert(table.concat(argv," "):find("--needed",1,true));return res(0,"core\tdemo\t1-1\n") end
        if argv[2]=="-Q" then return res(0,"demo 2-1\n") end
        if argv[2]=="-Qm" then return res(1) end
        error(table.concat(argv," "))
    end)
    patch(util,"passthrough",function(argv) called[#called+1]=table.concat(argv," ");return 0 end)
    patch(io,"read",function() error("noconfirm prompt") end)
    equal(update.run({color=false},cli.parse({"-Syyuu","--needed","--noconfirm"})),0)
    equal(called[1],"pacman -Syy --noconfirm")
    equal(called[2],"pacman -Suu --noconfirm --needed")
end)
scenario("mise à jour : collecte incomplète ne signifie jamais système à jour",function(patch)
    patch(util,"run",function(argv)
        if argv[2]=="-Sup" then return res(0) end
        if argv[2]=="-Qm" then return res(1,"","database unavailable") end
        error(table.concat(argv," "))
    end)
    patch(update,"display",function() error("false up-to-date message") end)
    equal(update.run({},{refresh=0}),1)
end)
scenario("mise à jour : sortie tronquée ou mal formée refusée",function(patch)
    for _,response in ipairs({{code=0,stdout="",stderr="",stdout_truncated=true},res(0,"not a transaction\n")}) do
        patch(util,"run",function() return response end)
        patch(update,"display",function() error("false success") end)
        equal(update.run({},{refresh=0}),1)
    end
end)
scenario("mise à jour : EOF annule avant la transaction",function(patch)
    patch(update,"check",function() return {{repo="core",name="demo",oldver="1",newver="2"}},{},{},nil,{} end)
    patch(io,"read",function() return nil end)
    patch(util,"passthrough",function() error("EOF installed packages") end)
    equal(update.run({color=false},{}),1)
end)
scenario("interruption : dépôt arrêté ne lance pas la partie AUR",function(patch)
    patch(util,"run",function(argv) return res(argv[3]=="repo-demo" and 0 or 1) end)
    patch(pacman,"passthrough",function() return 130 end)
    patch(build,"aur_many",function() error("AUR after SIGINT") end)
    equal(install.run({color=false},{"repo-demo","aur-demo"},{passthrough={}}),130)
end)
scenario("interruption : dépendance dépôt arrête le plan et interdit le nettoyage",function(patch)
    patch(pacman,"explicit_packages",function() return {} end)
    patch(builddeps,"start",function() return {} end)
    local interrupted
    patch(builddeps,"finish",function(_,_,opts) interrupted=opts.interrupted end)
    patch(build,"plan",function() return {missing={},order={"a","b"},bases={
        a={packages={"a"},explicit={a=true},dependencies={}},
        b={packages={"b"},explicit={b=true},dependencies={}}}} end)
    patch(deps,"repo_deps_of",function() return {"tool>=2"} end)
    patch(pacman,"passthrough",function(_,argv) equal(argv[#argv],"tool>=2");return 130 end)
    patch(build,"one_group",function() error("build after SIGINT") end)
    local results=build.aur_many({},{"a","b"},{})
    equal(#results,1);equal(results[1].status,"interrupted");assert(interrupted)
end)
scenario("AUR : réponse invalide ne pollue pas le cache négatif",function(patch)
    local invalid={"{}","[]","null",[[{"version":5,"type":"multiinfo","resultcount":0,"results":{}}]],'"text"',[[{"version":5,"type":"multiinfo","resultcount":1,"results":[]}]],
        [[{"version":5,"type":"multiinfo","resultcount":1,"results":[{"Name":"demo"}]}]],
        [[{"version":5,"type":"search","resultcount":0,"results":[]}]]}
    local good=[[{"version":5,"type":"multiinfo","resultcount":1,"results":[{"Name":"demo","Version":"1","PackageBase":"demo"}]}]]
    for _,bad in ipairs(invalid) do
        aur.clear_cache();local calls=0
        patch(babet.http,"get",function() calls=calls+1;return {status=200,body=calls==1 and bad or good} end)
        local value,err=aur.info({}, {"demo"});assert(value==nil and err)
        assert(aur.info({}, {"demo"}).demo);equal(calls,2)
    end
end)
scenario("AUR : absence RPC confirmée reste mise en cache",function(patch)
    aur.clear_cache();local calls=0
    patch(babet.http,"get",function() calls=calls+1;return {status=200,body=[[{"version":5,"type":"multiinfo","resultcount":0,"results":[]}]]} end)
    assert(aur.info({}, {"missing"}));assert(aur.info({}, {"missing"}));equal(calls,1)
end)
scenario("dépendances : contraintes distinctes préservées jusqu'à pacman",function(patch)
    patch(aur,"info",function() return {demo={Depends={"virtual>=2","virtual<4","virtual>=2"}}} end)
    patch(util,"run",function(argv) return res(argv[2]=="-T" and 127 or 0) end)
    local found=assert(deps.repo_deps_of({},"demo"));equal(table.concat(found,","),"virtual>=2,virtual<4")
end)
scenario("installation : ancienne dépendance explicite et --needed respectés",function(patch)
    local paths={["/tmp/dependency.pkg.tar.zst"]="dependency",["/tmp/new-dep.pkg.tar.zst"]="new-dep"}
    patch(babet,"fileExists",function(path) return paths[path]~=nil end)
    patch(util,"run_as",function() return res(0,"/tmp/dependency.pkg.tar.zst\n/tmp/new-dep.pkg.tar.zst\n") end)
    patch(util,"run",function(argv)
        if argv[2]=="-Qqe" then return res(0,"dependency\n") end
        if argv[2]=="-Qp" then return res(0,paths[argv[4]].."\n") end
        error(table.concat(argv," "))
    end)
    local calls={}
    patch(pacman,"passthrough",function(_,argv) calls[#calls+1]=table.concat(argv," ");return 0 end)
    assert(build.install({},"/tmp",{"dependency","new-dep"},{},{needed=true,noconfirm=true}))
    equal(calls[1],"-U --asdeps --needed --noconfirm /tmp/dependency.pkg.tar.zst /tmp/new-dep.pkg.tar.zst")
    equal(calls[2],"-D --asexplicit dependency")
    calls={}
    assert(build.install({},"/tmp",{"dependency"},{dependency=true},{reason="asdeps"}))
    equal(calls[1],"-U --asdeps /tmp/dependency.pkg.tar.zst");equal(#calls,1)
end)
scenario("installation : --needed ignore le build d'un paquet ordinaire à jour",function(patch)
    local group={base="demo",representative="demo",packages={"demo"},explicit={demo=true},dependencies={}}
    patch(build,"plan",function() return {missing={},order={"demo"},bases={demo=group}} end)
    patch(aur,"info",function() return {demo={Version="1-1"}} end)
    patch(util,"run",function(argv) equal(argv[2],"-Q");return res(0,"demo 1-1\n") end)
    patch(util,"vercmp",function() return 0 end)
    patch(deps,"repo_deps_of",function() error("unnecessary build dependencies") end)
    patch(build,"one_group",function() error("unnecessary build") end)
    local result=build.aur_many({},{"demo"},{needed=true})
    equal(result[1].status,"skipped");assert(result[1].ok)
end)
scenario("nettoyage : PKGDEST extérieur supprimé uniquement sous le compte de build",function(patch)
    patch(util,"is_root",function() return true end)
    local removed
    patch(util,"run_as",function(user,argv)
        equal(user,"yaourt");equal(argv[1],"rm");equal(argv[3],"--");removed=argv[4];return res(0)
    end)
    patch(babet,"remove",function() error("root deletion") end)
    assert(util.remove_artifact({},"/external/PKGDEST/demo.pkg.tar.zst"))
    equal(removed,"/external/PKGDEST/demo.pkg.tar.zst")
    removed=nil;assert(not util.remove_artifact({},"/etc/passwd"));assert(removed==nil)
end)
scenario("cache : root nettoie le même répertoire que celui des builds",function(patch)
    patch(util,"is_root",function() return true end)
    patch(babet.user,"get",function(name) equal(name,"yaourt");return {home="/var/cache/yaourt"} end)
    local cfg=assert(build.environment({builddir="/root/.cache/yaourt"}))
    equal(cfg.builddir,"/var/cache/yaourt/.cache/yaourt");equal(cfg.build_user,"yaourt")
end)
scenario("VCS : mise à jour d'un sous-paquet ne valide pas son frère",function(patch)
    local path="/tmp/yaourt-vcs-siblings-"..babet.pid()
    babet.remove(path)
    local cfg={vcs_state_file=path}
    patch(vcs,"snapshot",function() return "remote revision" end)
    assert(vcs.remember(cfg,"suite-git","remote revision",{"one-git"}))
    local entries={{in_aur=true,name="one-git",pkgbase="suite-git"},{in_aur=true,name="two-git",pkgbase="suite-git"}}
    equal(#vcs.mark_updates(cfg,entries),0)
    assert(not entries[1].has_update);assert(entries[2].has_update)
    local file=assert(io.open(path,"w"));file:write("YAOURT-VCS-1\nsuite-git\told\n");file:close()
    equal(next(assert(vcs.load(cfg))),nil)
    assert(babet.remove(path))
end)
scenario("installation : une dépendance dépôt auparavant explicite le reste",function(patch)
    patch(util,"run",function(argv)
        if argv[2]=="-Qqe" then return res(0,"compiler\neditor\n") end
        if argv[2]=="-Qdq" then return res(0,"compiler\nnew-build-tool\n") end
        error(table.concat(argv," "))
    end)
    local calls={}
    patch(pacman,"passthrough",function(_,argv) calls[#calls+1]=table.concat(argv," ");return 0 end)
    equal(pacman.install_dependencies({}, {"virtual-compiler>=2","new-build-tool"},{}),0)
    equal(calls[1],"-S --asdeps --needed virtual-compiler>=2 new-build-tool")
    equal(calls[2],"-D --asexplicit compiler")
end)
for _,step in ipairs({"fetch","review","packagelist"}) do
    scenario("interruption : arrêt du pipeline pendant "..step,function(patch)
        patch(util,"is_root",function() return false end)
        patch(util,"run",function() return res(1) end)
        patch(aur,"info",function() return {demo={Version="1"}} end)
        patch(build,"prepare",function()
            if step=="fetch" then return nil,"git interrupted",130 end
            return {path="/tmp/not-executed"}
        end)
        patch(build,"review",function()
            if step=="review" then return false,"review interrupted",130 end
            return true
        end)
        patch(build,"clean_stale",function() return false,130 end)
        patch(build,"make",function() error("build after interruption") end)
        local results=build.one_group({builddir="/tmp",color=false},{representative="demo",base="demo",packages={"demo"},explicit={demo=true}}, {})
        equal(results[1].status,"interrupted")
    end)
end
scenario("interruption : récupération Git conserve le code 130",function(patch)
    patch(aur,"info",function() return {demo={Name="demo",PackageBase="demo",Version="1"}} end)
    patch(babet,"mkdir",function() return true end)
    patch(babet,"isDir",function() return false end)
    patch(util,"run_as",function(_,argv) equal(argv[2],"clone");return res(130) end)
    local value,_,code=require("lib.fetch").one({builddir="/tmp"},"demo")
    equal(value,nil);equal(code,130)
end)

scenario("interruption : requête de dépendances arrête la résolution",function(patch)
    patch(aur,"info",function() return {demo={Name="demo",PackageBase="demo",Depends={"tool"}}} end)
    local calls=0
    patch(util,"run",function(argv) calls=calls+1;equal(argv[2],"-T");return res(130) end)
    local value,_,code=deps.resolve_many({}, {"demo"})
    equal(value,nil);equal(code,130);equal(calls,1)
    local finished=false
    patch(builddeps,"finish",function() finished=true end)
    local result=build.aur_many({}, {"demo"})
    equal(result[1].status,"interrupted");assert(not finished)
end)
scenario("interruption : SIGTERM conservé dans le bilan",function()
    equal(require("lib.display").build_summary(require("lib.color").new(false),
        {build.result("interrupted","demo","SIGTERM",143)}),143)
end)

scenario("pacdiff : argument vide distinct de --nocolor",function(patch)
    patch(babet,"which",function() return "/usr/bin/pacdiff" end)
    patch(util,"is_root",function() return true end)
    patch(util,"passthrough",function(argv)
        equal(#argv,4);equal(argv[1],"pacdiff");equal(argv[2],"--nocolor")
        equal(argv[3],"");equal(argv[4],"--output")
        return 0
    end)
    equal(require("lib.pacdiff").run({color=false},{"","--output"}),0)
end)
scenario("nettoyage : erreur nomme la transaction réellement lancée",function(patch)
    patch(util,"run",function(argv)
        if argv[2]=="-Qdtq" then return res(0,"new-tool\n") end
        assert(table.concat(argv," "):find("--print --print-format",1,true))
        return res(0,"new-tool\n")
    end)
    patch(pacman,"passthrough",function(_,argv)
        equal(table.concat(argv," "),"-Rn --noconfirm new-tool");return 7
    end)
    local warning
    patch(require("lib.log"),"warn",function(message) warning=message end)
    local outcome=builddeps.finish({color=false},{mode="always",before={}},{})
    equal(outcome.status,"failed");equal(outcome.code,7)
    assert(warning:find("pacman -Rn --noconfirm",1,true))
    assert(not warning:find("pacman -Rns",1,true))
end)

for _, case in ipairs({
    {name="pfetch-git", installed="r432.a906ff8-1", target="r340.e18a095-1", key="build.heading_installed"},
    {name="pfetch-git", target="r340.e18a095-1", key="build.heading"},
    {name="pfetch-git", installed="r432.a906ff8-1", target="r340.e18a095-1", changed=true, key="build.heading_vcs"},
    {name="demo", installed="1-1", target="2-1", key="build.heading_update"},
}) do
    scenario("affichage : version de build honnête ("..case.key..")",function(patch)
        local lines={}
        patch(_G,"print",function(line) lines[#lines+1]=line end)
        patch(util,"is_root",function() return false end)
        patch(util,"run",function(argv)
            equal(argv[2],"-Q")
            return case.installed and res(0,case.name.." "..case.installed.."\n") or res(1)
        end)
        patch(aur,"info",function() return {[case.name]={Version=case.target}} end)
        -- Stop after the heading: no actual checkout, build or installation.
        patch(build,"prepare",function() return nil,"fixture stop",1 end)
        build.one_group({color=false,builddir="/tmp"},
            {base=case.name,representative=case.name,packages={case.name}},
            {vcs_packages=case.changed and {[case.name]=true} or nil})
        equal(lines[2],"==> "..require("lib.i18n").t(case.key,{
            package=case.name,version=case.installed,old_version=case.installed,new_version=case.target}))
        if case.name=="pfetch-git" then assert(not lines[2]:find(case.target,1,true)) end
    end)
end

end
