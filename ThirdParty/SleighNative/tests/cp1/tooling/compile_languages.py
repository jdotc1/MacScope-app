#!/usr/bin/env python3
"""Recompile the three resources in place; never retain a stale output on failure."""
import argparse,hashlib,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--compiler',required=True,type=pathlib.Path);p.add_argument('--resources',required=True,type=pathlib.Path);p.add_argument('--report',required=True,type=pathlib.Path);p.add_argument('--variants',nargs='+',choices=('le','be','apple'),default=('le','be','apple'));a=p.parse_args();rows=[]
for variant in a.variants:
    stem={'le':'AARCH64','be':'AARCH64BE','apple':'AARCH64_AppleSilicon'}[variant]
    sla=a.resources/(stem+'.sla');sla.unlink(missing_ok=True)
    proc=subprocess.run([str(a.compiler.resolve()),stem+'.slaspec'],cwd=a.resources)
    row={'source':stem+'.slaspec','exitStatus':proc.returncode}
    if sla.is_file():row.update(sha256=hashlib.sha256(sla.read_bytes()).hexdigest(),bytes=sla.stat().st_size)
    rows.append(row)
a.report.write_text(json.dumps({'compilerSHA256':hashlib.sha256(a.compiler.read_bytes()).hexdigest(),'results':rows},indent=2)+'\n');print(json.dumps(rows,indent=2));raise SystemExit(any(r['exitStatus'] for r in rows))
