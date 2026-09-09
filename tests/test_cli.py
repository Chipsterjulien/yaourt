#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the actual entry point in both modes with an isolated fake pacman."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

babet,source,executable=(Path(value).resolve() for value in sys.argv[1:4])
with tempfile.TemporaryDirectory(prefix='yaourt-cli-tests-') as temp:
    work=Path(temp);stage=work/'program';stage.mkdir();bin_dir=work/'bin';bin_dir.mkdir()
    shutil.copyfile(source/'main.lua',stage/'main.lua');shutil.copytree(source/'lib',stage/'lib')
    log=work/'calls.jsonl'
    stub=bin_dir/'pacman'
    stub.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
args=sys.argv[1:]
with open(os.environ['YAOURT_PROCESS_LOG'],'a') as file: file.write(json.dumps(args)+'\\n')
if args[0]=='-Si': sys.exit(1)
if args[0]=='-Sup': print('extra\\treplacement\\t2-1');sys.exit(0)
if args==['-Q']: print('old-name 1-1');sys.exit(0)
if args==['-Qm']: sys.exit(1)
if args==['-Su']: sys.exit(0)
raise SystemExit('UNEXPECTED PACMAN: '+str(args))
''');stub.chmod(0o755)
    sudo=bin_dir/'sudo'
    sudo.write_text('#!'+sys.executable+'\nimport os,sys\nassert sys.argv[1]=="pacman"\nos.execv('+repr(str(stub))+',sys.argv[1:])\n');sudo.chmod(0o755)
    cfg=work/'cfg';cfg.mkdir();(cfg/'config.toml').write_text('color=false\nlanguage="en"\ndevel=false\nlist_aur=false\n')
    env={**os.environ,'PATH':str(bin_dir)+os.pathsep+os.environ['PATH'],'YAOURT_PROCESS_LOG':str(log),'XDG_CONFIG_HOME':str(work/'config'),'LANGUAGE':'en'}
    for mode,prefix in [('folder',[str(babet),str(stage)]),('embedded',[str(executable)])]:
        for args in [['-Syu','--downloadonly'],['-Syuw'],['-Syu','--root=/guest'],['-S','--root','/guest','aur-demo'],
                ['-Syu','--ignore=old-name'],['-S','--ignore','old-name','aur-demo'],['-Sy','aur-demo']]:
            log.unlink(missing_ok=True)
            result=subprocess.run(prefix+args,cwd=work,env=env,text=True,capture_output=True)
            assert result.returncode==1,(mode,args,result.stdout,result.stderr)
            assert not log.exists(),(mode,args,log.read_text())
        for args in [['-wS','aur-demo'],['-Sp','aur-demo'],['--sync','--print','aur-demo']]:
            log.unlink(missing_ok=True)
            result=subprocess.run(prefix+args,cwd=work,env=env,text=True,capture_output=True)
            assert result.returncode==1,(mode,args,result.stdout,result.stderr)
            assert [json.loads(line) for line in log.read_text().splitlines()]==[['-Si','aur-demo']]
        log.unlink(missing_ok=True)
        result=subprocess.run(prefix+['-Su'],cwd=work,env=env,input='y\n',text=True,capture_output=True)
        assert result.returncode==0,(mode,result.stdout,result.stderr)
        calls=[json.loads(line) for line in log.read_text().splitlines()]
        assert calls[-1]==['-Su'] and not any('-Sy' in row for row in calls),calls
        assert 'replacement' in result.stdout and 'up to date' not in result.stdout,result.stdout
        print('[PASS] entrée '+mode+' : 10 refus sûrs et remplacement seul sans synchronisation implicite')
