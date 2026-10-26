#!/usr/bin/env python3
"""Actual SLEIGH helper-input dataflow contracts; NOT numerical helper emulation."""
import argparse, hashlib, json, time
from pathlib import Path
from rx17_semantics import VM, Lifter, SLA
ALIASES=((0,1,2),(1,1,2),(2,1,2),(0,1,1),(3,3,3),(0,17,18),(31,30,31))
def mask(n): return (1<<(8*n))-1

def cases():
    for family,base in (('bfdot',0x0f40f000),('sudot',0x0f00f000),('usdot',0x0f80f000)):
      for q in (0,1):
       for index in range(4):
        for rd,rn,rm in ALIASES:
         word=base|(q<<30)|rd|(rn<<5)|(rm<<16)|((index&1)<<21)|((index>>1)<<11)
         yield dict(family=family,form='indexed',word=word,rd=rd,rn=rn,rm=rm,active=8<<q,pairbytes=4,index=index)
    for q in (0,1):
     for rd,rn,rm in ALIASES:
      yield dict(family='bfdot',form='vector',word=0x2e40fc00|(q<<30)|rd|(rn<<5)|(rm<<16),rd=rd,rn=rn,rm=rm,active=8<<q,pairbytes=8<<q,index=None)
    for size,q in ((1,0),(1,1),(2,0),(2,1),(3,1)):
     for rotation in range(4):
      for rd,rn,rm in ALIASES:
       word=0x2e00c400|(size<<22)|(q<<30)|(rotation<<11)|rd|(rn<<5)|(rm<<16)
       yield dict(family='fcmla',form='vector',word=word,rd=rd,rn=rn,rm=rm,active=8<<q,pairbytes=8<<q,index=None,element=1<<size,rotation=rotation*90)
    for size,q,indices in ((1,0,range(2)),(1,1,range(4)),(2,1,range(2))):
     for index in indices:
      for rotation in range(4):
       for rd,rn,rm in ALIASES:
        select=((index&1)<<21)|((index>>1)<<11) if size==1 else index<<11
        word=0x2f001000|(size<<22)|(q<<30)|(rotation<<13)|select|rd|(rn<<5)|(rm<<16)
        yield dict(family='fcmla',form='indexed',word=word,rd=rd,rn=rn,rm=rm,active=8<<q,pairbytes=2*(1<<size),index=index,element=1<<size,rotation=rotation*90)

def check(lifter,be,case):
    vm=VM(be); regs=set((case['rd'],case['rn'],case['rm']))
    for r in regs:
        # Every byte differs by lane and register; all upper bytes are nonzero.
        vm.set('z'+str(r),int.from_bytes(bytes(((17+r*29+i*7)%255)+1 for i in range(32)),'little'))
    old={r:vm.get('z'+str(r)) for r in regs}
    n=case['active']; m=case['pairbytes']; index=case['index']
    expected=[old[case['rd']]&mask(n),old[case['rn']]&mask(n),(old[case['rm']]>>(0 if index is None else 8*m*index))&mask(m)]
    sizes=[n,n,m]
    if case['family']=='fcmla': expected += [case['rotation'],case['element']]; sizes += [2,1]
    sentinel=int.from_bytes(bytes((0xa5+i*3)&255 for i in range(n)),'little')
    calls=[]
    def helper(values,actual_sizes,out):
        assert values==expected,('arguments',list(map(hex,values)),list(map(hex,expected)))
        assert actual_sizes==sizes,('sizes',actual_sizes,sizes)
        assert out is not None and out[2]==n,('output width',out,n)
        calls.append(values)
        return sentinel
    ops=lifter.get(case['word']); ids={ins[0][1] for op,out,ins in ops if op=='CALLOTHER'}
    assert len(ids)==1,('helper count',ids)
    vm.helpers={i:helper for i in ids}; vm.run(ops)
    assert len(calls)==1,('helper invocations',len(calls))
    assert vm.get('z'+str(case['rd']))==sentinel,('destination clearing',hex(vm.get('z'+str(case['rd']))),hex(sentinel))
    for r in regs-{case['rd']}: assert vm.get('z'+str(r))==old[r],('source mutated',r)
    return next(iter(ids))

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--tree',type=Path,required=True); p.add_argument('--languages',type=Path); p.add_argument('--lifter',type=Path,required=True); p.add_argument('--pspec',type=Path); p.add_argument('--variant',choices=list(SLA),action='append'); p.add_argument('--family',choices=['bfdot','sudot','usdot','fcmla'],action='append'); p.add_argument('--report',type=Path,required=True); a=p.parse_args()
    a.languages=a.languages or a.tree/'Ghidra/Processors/AARCH64/data/languages'; started=time.monotonic()
    result={'scope':'Actual p-code CALLOTHER argument, output-width and upper-clearing contracts; no numerical helper semantics or native-app claim','aliases':ALIASES,'variants':{}}
    failed=False
    for variant in a.variant or list(SLA):
        lifter=Lifter(a,variant); row={'passed':{},'helper_ids':{},'failures':[]}; result['variants'][variant]=row; family_failed=set()
        for case in cases():
            family=case['family']; group=family+'_'+case['form']
            if a.family and family not in a.family: continue
            if group in family_failed: continue
            try:
                helper=check(lifter,variant=='be',case); row['passed'][group]=row['passed'].get(group,0)+1
                if family in row['helper_ids']: assert row['helper_ids'][family]==helper,('helper changed',family,helper)
                row['helper_ids'][family]=helper
            except Exception as error:
                failed=True; family_failed.add(group); row['failures'].append({'case':case,'error':repr(error)})
        row['sla_sha256']=hashlib.sha256((a.languages/SLA[variant]).read_bytes()).hexdigest()
    result['wall_seconds']=round(time.monotonic()-started,3); a.report.write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result,indent=2)); raise SystemExit(1 if failed else 0)
if __name__=='__main__': main()
