#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real local Git review and privilege checks; never invokes pacman/makepkg."""
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile

babet, source = map(lambda x: Path(x).resolve(), sys.argv[1:3])
def command(*args, **kwargs):
    return subprocess.run(list(map(str,args)),check=True,capture_output=True,text=True,**kwargs)
def fixture(work):
    upstream=work/'upstream'; remotes=work/'remotes';remotes.mkdir()
    command('git','init','-q',upstream)
    (upstream/'PKGBUILD').write_text('pkgname=review-demo\npkgver=1\npkgrel=1\n')
    command('git','-C',upstream,'add','PKGBUILD')
    command('git','-C',upstream,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture')
    command('git','clone','--bare',upstream,remotes/'review-demo.git')
    for editor_name in ('editor with desktop', 'editor without desktop'):
        editor=work/editor_name
        editor.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
keys=('DISPLAY','WAYLAND_DISPLAY','XAUTHORITY','DBUS_SESSION_BUS_ADDRESS','SESSION_MANAGER','XDG_RUNTIME_DIR')
desktop=Path(sys.argv[0]).name=='editor with desktop'
for key in keys:
    assert os.environ.get(key)==('yaourt-fixture-'+key if desktop else None), key
assert os.environ.get('TERM')=='xterm'
assert os.environ.get('LANG')=='C'
assert len(sys.argv)==2 and Path(sys.argv[1]).name=='PKGBUILD'
assert 'pkgname=review-demo' in Path(sys.argv[1]).read_text()
''')
        editor.chmod(0o755)

with tempfile.TemporaryDirectory(prefix='yaourt-review-tests-') as temp:
    base=Path(temp)
    stage=base/'stage';stage.mkdir()
    shutil.copyfile(source/'tests/review_local/main.lua',stage/'main.lua')
    shutil.copytree(source/'lib',stage/'lib')
    exe=base/'review-tests'
    command(babet,'--create-exe',stage,exe)
    for mode in ('folder','embedded'):
        work=base/mode;work.mkdir();fixture(work)
        env=os.environ.copy();env.update(YAOURT_TEST_SOURCE=str(source),YAOURT_TEST_WORK=str(work))
        for key in ('DISPLAY','WAYLAND_DISPLAY','XAUTHORITY','DBUS_SESSION_BUS_ADDRESS','SESSION_MANAGER','XDG_RUNTIME_DIR'):
            env[key]='yaourt-fixture-'+key
        env.update(TERM='xterm', LANG='C')
        subprocess.run([str(babet),str(stage)] if mode=='folder' else [str(exe)],env=env,check=True)
    if os.geteuid()==0 and shutil.which('runuser'):
        # A root-owned victim deliberately has a valid package suffix. Even a
        # malicious packagelist must not turn its deletion into a root action.
        try:
            nobody=pwd.getpwnam('nobody')
        except KeyError:
            nobody=None
        if nobody and Path('/proc/self/uid_map').exists():
            uid_ranges=[list(map(int,line.split())) for line in Path('/proc/self/uid_map').read_text().splitlines()]
            gid_ranges=[list(map(int,line.split())) for line in Path('/proc/self/gid_map').read_text().splitlines()]
            if not any(start <= nobody.pw_uid < start+length for start,_,length in uid_ranges) or not any(start <= nobody.pw_gid < start+length for start,_,length in gid_ranges):
                nobody=None
                print('[SKIP] contrôle réel sous nobody : UID/GID non disponibles dans cet espace de noms')
        if nobody:
            base.chmod(0o755)
            private=base/'root-only';private.mkdir(mode=0o700)
            victim=private/'victim.pkg.tar.zst';victim.write_text('KEEP')
            output=base/'external-pkgdest';output.mkdir()
            os.chown(output,nobody.pw_uid,nobody.pw_gid)
            artifact=output/'demo.pkg.tar.zst';artifact.write_text('REMOVE')
            os.chown(artifact,nobody.pw_uid,nobody.pw_gid)
            program=base/'privileges';program.mkdir()
            shutil.copytree(source/'lib',program/'lib')
            (program/'main.lua').write_text('''local util=require("lib.util")
local cfg={build_user="nobody"}
assert(not util.remove_artifact(cfg,assert(os.getenv("VICTIM"))))
assert(util.remove_artifact(cfg,assert(os.getenv("ARTIFACT"))))
''')
            subprocess.run([str(babet),str(program)],check=True,env={**os.environ,'VICTIM':str(victim),'ARTIFACT':str(artifact)})
            assert victim.read_text()=='KEEP' and not artifact.exists()
            print('[PASS] suppression réelle sous nobody : fichier root préservé, PKGDEST externe nettoyé')
