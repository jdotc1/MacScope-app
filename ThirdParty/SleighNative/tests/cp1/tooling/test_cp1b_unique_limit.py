#!/usr/bin/env python3
"""Exercise the bundled compiler's unique-temporary width guard unmodified."""
import argparse,hashlib,json,pathlib,subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('--compiler',required=True,type=pathlib.Path);p.add_argument('--report',required=True,type=pathlib.Path);a=p.parse_args();rows=[]
for width in [256,512,65536]:
 source='''define endian=little;
define alignment=1;
define space ram type=ram_space size=8 default;
define space register type=register_space size=8;
define register offset=0 size=1 [ r ];
define token instr(8) op=(0,7);
:test is op=0 { local wide:%d=zext(r); wide=wide+1; r=wide:1; }
'''%width
 with tempfile.TemporaryDirectory(prefix='cp1b-unique-limit-') as work:
  path=pathlib.Path(work)/'test.slaspec';path.write_text(source);command=[str(a.compiler.resolve()),str(path)];proc=subprocess.run(command,capture_output=True,text=True)
  rows.append({'bytes':width,'source':source,'command':command,'exitStatus':proc.returncode,'stdout':proc.stdout,'stderr':proc.stderr,'producedSLA':path.with_suffix('.sla').exists()})
  if width==256:assert proc.returncode==0,rows[-1]
  else:assert proc.returncode!=0 and 'larger than 256 bytes' in proc.stderr and not path.with_suffix('.sla').exists(),rows[-1]
report={'scope':__doc__,'compilerSHA256':hashlib.sha256(a.compiler.read_bytes()).hexdigest(),'rows':rows};a.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
