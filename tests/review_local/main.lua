-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real Git/filesystem review regressions, no package installation.
local root=assert(os.getenv("YAOURT_TEST_SOURCE"))
local work=assert(os.getenv("YAOURT_TEST_WORK"))
package.path=root.."/?.lua;"..package.path
local util=require("lib.util")
local aur=require("lib.aur")
local build=require("lib.build")
local fetch=require("lib.fetch")
local review=require("lib.review")
require("lib.i18n").set_language("en")
local passed=0
local function test(name,fn)
    fn();passed=passed+1;print("[PASS] revue : "..name)
end
local cfg={builddir=work.."/clones",aur_url="file://"..work.."/remotes",editor="fixture-editor",color=false,_review_state_dir=work.."/approvals"}
local function write(path,value)
    local f=assert(io.open(path,"w"));assert(f:write(value));assert(f:close())
end
local original_info,original_pass,original_read=aur.info,util.passthrough,io.read
local original_run_as=util.run_as
local opened,answer=0,"n"
aur.info=function() return {demo={Name="demo",PackageBase="review-demo",Version="1"}} end
util.passthrough=function(argv) assert(argv[1]=="fixture-editor");opened=opened+1;return 0 end
io.read=function() return answer end
local first=assert(fetch.one(cfg,"demo"))
test("un refus n'est pas effacé par le prochain pull",function()
    assert(not build.review(cfg,first))
    local second=assert(fetch.one(cfg,"demo"));assert(not second.updated)
    assert(not build.review(cfg,second));assert(opened==2)
end)
test("EOF refuse et ne crée pas d'approbation",function()
    answer=nil;assert(not build.review(cfg,first));assert(opened==3)
end)
test("éditeur interrompu ne crée pas d'approbation",function()
    util.passthrough=function() return 130 end
    local accepted,_,code=build.review(cfg,first);assert(not accepted and code==130)
    util.passthrough=function() opened=opened+1;return 0 end
end)
test("approbation réussie et contenu inchangé",function()
    answer="y";assert(build.review(cfg,first));local before=opened
    assert(build.review(cfg,first));assert(opened==before)
end)
test("modification locale impose une nouvelle revue",function()
    local f=assert(io.open(first.path.."/PKGBUILD","a"));f:write("# local edit\n");f:close()
    local before=opened;answer="n";assert(not build.review(cfg,first));assert(opened==before+1)
    answer="y";assert(build.review(cfg,first));before=opened
    assert(build.review(cfg,first));assert(opened==before)
end)
local function git(...)
    local argv={"git"};for _,a in ipairs({...}) do argv[#argv+1]=a end
    local r,e=util.run(argv);assert(util.complete(r),e or (r and r.stderr));return r.stdout
end
test("une mise à jour refusée reste à revoir après un autre pull",function()
    git("-C",first.path,"checkout","--","PKGBUILD")
    answer="y";assert(build.review(cfg,first))
    write(work.."/upstream/PKGBUILD","pkgname=review-demo\npkgver=2\npkgrel=1\n")
    git("-C",work.."/upstream","add","PKGBUILD")
    git("-C",work.."/upstream","-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","update")
    git("-C",work.."/upstream","push",work.."/remotes/review-demo.git","HEAD")
    local changed=assert(fetch.one(cfg,"demo"));assert(changed.updated)
    answer="n";assert(not build.review(cfg,changed))
    changed=assert(fetch.one(cfg,"demo"));assert(not changed.updated)
    assert(not build.review(cfg,changed))
end)
test("erreur et troncature du diff arrêtent la validation",function()
    for _,res in ipairs({{code=128,stdout="",stderr="bad revision"},{code=0,stdout="partial diff",stderr="",stdout_truncated=true}}) do
        util.run_as=function(user,argv,opts)
            if argv[4]=="diff" then return res end
            return original_run_as(user,argv,opts)
        end
        answer="y";assert(not build.review(cfg,first))
    end
    util.run_as=original_run_as
    assert(build.review(cfg,first))
end)
test("échec de la liste de fichiers et lien symbolique refusés",function()
    util.run_as=function(user,argv,opts)
        if argv[4]=="ls-files" then return {code=130,stdout="",stderr=""} end
        return original_run_as(user,argv,opts)
    end
    local accepted,_,code=build.review(cfg,first);assert(not accepted and code==130)
    util.run_as=original_run_as
    git("-C",first.path,"mv","PKGBUILD","original")
    local r=util.run({"ln","-s","original",first.path.."/PKGBUILD"});assert(util.complete(r))
    git("-C",first.path,"add","PKGBUILD")
    assert(not build.review(cfg,first))
end)
test("répertoire d'approbation accessible au compte de build refusé",function()
    local r=util.run({"chmod","777",work.."/approvals"});assert(util.complete(r))
    assert(not build.review(cfg,first))
    assert(util.complete(util.run({"chmod","700",work.."/approvals"})))
end)
-- A second fresh checkout obtained by -G still requires approval.
test("récupération sans revue ne vaut pas approbation",function()
    cfg.builddir=work.."/get-only"
    local meta=assert(fetch.one(cfg,"demo"));answer="n"
    meta=assert(fetch.one(cfg,"demo"));assert(not meta.first_clone)
    assert(not build.review(cfg,meta))
end)
local editor_meta=assert(fetch.one(cfg,"demo"))
test("éditeur utilisateur conserve son environnement graphique",function()
    cfg.editor=work.."/editor with desktop"
    util.passthrough=function(argv)
        assert(argv[1]==cfg.editor and argv[2]==editor_meta.path.."/PKGBUILD")
        return original_pass(argv)
    end
    local accepted,why=build.review(cfg,editor_meta)
    assert(not accepted and why=="refused")
end)
test("éditeur sous compte de build sans environnement graphique hérité",function()
    cfg.editor=work.."/editor without desktop"
    cfg.build_user="fixture-build-user"
    -- No alternate UID is required here. Check the runuser boundary, then
    -- execute the REAL env/editor subprocess to inspect its environment.
    util.run_as=function(user,argv,opts)
        assert(user==cfg.build_user)
        return original_run_as(nil,argv,opts)
    end
    util.passthrough=function(argv)
        assert(argv[1]=="runuser" and argv[2]=="-u" and argv[3]==cfg.build_user and argv[4]=="--")
        assert(argv[5]=="env")
        assert(argv[#argv-1]==cfg.editor and argv[#argv]==editor_meta.path.."/PKGBUILD")
        local child={};for i=5,#argv do child[#child+1]=argv[i] end
        return original_pass(child)
    end
    local accepted,why=build.review(cfg,editor_meta)
    assert(not accepted and why=="refused")
end)
test("échec de l'éditeur signalé sans demande d'approbation",function()
    util.passthrough=function() return 1 end
    io.read=function() error("confirmation after editor failure") end
    local accepted,why,code=build.review(cfg,editor_meta)
    assert(not accepted and code==1)
    assert(why:find("PKGBUILD",1,true) and why:find(cfg.editor,1,true))
    cfg.build_user=nil
    util.run_as=original_run_as
end)
aur.info,util.passthrough,io.read=original_info,original_pass,original_read
print("=== "..passed.." régressions de revue PASS ===")
