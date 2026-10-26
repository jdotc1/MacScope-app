#!/usr/bin/env python3
"""Lift evidence words; preserve full p-code and exact exporter range diagnostics."""
from __future__ import annotations
import argparse,collections,hashlib,json,pathlib,re,subprocess
VN=re.compile(r'\((\w+),(0x[0-9a-f]+),(\d+)\)')
VARIANTS={'le':'AARCH64.sla','be':'AARCH64BE.sla','apple':'AARCH64_AppleSilicon.sla'}
def words_from(value,trail=''):
    if isinstance(value,dict):
        for k,v in value.items():
            if k in ('word','encoding') and isinstance(v,str) and re.fullmatch(r'(?:0x)?[0-9a-fA-F]{8}',v):yield int(v,16),trail+'/'+k
            elif k=='words' and isinstance(v,list):
                for i,w in enumerate(v):
                    if isinstance(w,str) and re.fullmatch(r'(?:0x)?[0-9a-fA-F]{8}',w):yield int(w,16),trail+f'/words/{i}'
            else:yield from words_from(v,trail+'/'+k)
    elif isinstance(value,list):
        for i,v in enumerate(value):yield from words_from(v,trail+f'/{i}')
def lift_batch(lifter,path,words,pspec=None):
    cmd=[str(pathlib.Path(lifter).resolve()),'batch',str(pathlib.Path(path).resolve())]
    if pspec:cmd+=['-s',str(pathlib.Path(pspec).resolve())]
    p=subprocess.run(cmd,input=''.join(w.to_bytes(4,'little').hex()+'\n' for w in words),capture_output=True,text=True,check=True)
    rows=[json.loads(x) for x in p.stdout.splitlines()]
    if len(rows)!=len(words):raise RuntimeError(f'lifter returned {len(rows)} rows for {len(words)} inputs')
    return rows

def metrics(row):
    ns=[{'space':m[0],'offset':int(m[1],16),'size':int(m[2]),'endExclusive':int(m[1],16)+int(m[2])} for m in VN.findall(row['pcode'])]
    ops=[]
    for line in row['pcode'].splitlines():
        code=line.split(' = ',1)[-1].split();
        if code:ops.append(code[0])
    return {'pcodeOpCount':len(ops),'intraInstructionBranchCount':sum(o in ('BRANCH','CBRANCH') for o in ops),'callotherCount':ops.count('CALLOTHER'),'largestVarnodeEnd':max(ns,key=lambda x:x['endExclusive']) if ns else None,'largestVarnodeSize':max((n['size'] for n in ns),default=0),'u64OverflowVarnodes':[n for n in ns if n['endExclusive']>2**64-1]}

def main():
    p=argparse.ArgumentParser();p.add_argument('--lifter',required=True,type=pathlib.Path);p.add_argument('--resources',required=True,type=pathlib.Path);p.add_argument('--evidence',required=True,type=pathlib.Path);p.add_argument('--report',required=True,type=pathlib.Path);a=p.parse_args()
    refs=collections.defaultdict(list)
    for name in ('lane21/remaining-input-manifest.json','lane-ak/per-word-table.json','lane-am/am-input-manifest.json','lane-am/amg-input-manifest.json'):
        for w,loc in words_from(json.loads((a.evidence/name).read_text())):refs[w].append({'manifest':name,'jsonPointer':loc})
    words=sorted(refs);results=[];digests={}
    for variant,filename in VARIANTS.items():
        path=a.resources/filename;digests[variant]=hashlib.sha256(path.read_bytes()).hexdigest()
        for word,row in zip(words,lift_batch(a.lifter,path,words,a.resources/'AARCH64.pspec')):
            row.update(word=f'{word:08x}',variant=variant,sources=refs[word]);row.update(metrics(row));results.append(row)
    summary={v:{'words':sum(r['variant']==v for r in results),'decoded':sum(r['variant']==v and r['decoded'] for r in results),'withRelativeBranches':sum(r['variant']==v and r['intraInstructionBranchCount']>0 for r in results),'withRangeOverflow':sum(r['variant']==v and bool(r['u64OverflowVarnodes']) for r in results)} for v in VARIANTS}
    a.report.write_text(json.dumps({'scope':'Raw one-instruction SLEIGH; not native decompiler blocks or XPC acceptance','sha256':digests,'summary':summary,'results':results},indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
