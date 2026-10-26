#!/usr/bin/env python3
"""Bounded RX18 decode/effect receipt. No native-provider or hardware execution."""
from __future__ import annotations
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import shutil
from rx17_semantics import VM, parse

ROOT = Path(__file__).resolve().parents[3]
RESOURCES = ROOT / 'ThirdParty/SleighNative/AARCH64'
LIFTER = ROOT / 'ThirdParty/SleighNative/package/bin/sleigh-lift'
LANGUAGES = Path('Ghidra/Processors/AARCH64/data/languages')
VARIANTS = {'le':'AARCH64.sla', 'be':'AARCH64BE.sla', 'apple':'AARCH64_AppleSilicon.sla'}
# These are state tokens, not physical ZA tile storage or a vector-length claim.
SVL = ('register',0x7000,8)
ZA = ('register',0x7008,8)
ZT0 = ('register',0x7040,64)

def normal(text):
    text = text.lower().strip().replace('mova ', 'mov ')
    text = re.sub(r'(?<![a-z0-9])(-?)0x([0-9a-f]+)', lambda m:str((-1 if m[1] else 1)*int(m[2],16)), text)
    text = re.sub(r'(za)0x([0-9a-f]+)', lambda m:m[1]+str(int(m[2],16)),text)
    text = re.sub(r'^fmov (z[0-9]+\.[hsd]), #0\.0$', r'mov \1, #0', text)
    return re.sub(r'\s+', '', text)

def lift(word, variant, tree, action):
    p = subprocess.run([str(LIFTER),action,VARIANTS[variant],int(word,16).to_bytes(4,'little').hex(),'-p',str(tree),'-s',str(RESOURCES/'AARCH64.pspec')],capture_output=True,text=True,timeout=30)
    result=(p.stdout+p.stderr).strip()
    if 'Unable to resolve constructor' in result or 'BadDataError' in result:return None
    if p.returncode:raise RuntimeError((word,variant,p.returncode,result))
    return re.sub(r'^0x[0-9a-f]+:\s*','',result) if action=='disassemble' else result

def check_numeric(word,ops,be):
    """Exact normal-path RDSVL and fixed 512-bit ZT0 memory operations."""
    value=int(word,16);count=0
    if value&0xfffff800==0x04bf5800:
        rd=value&31;imm=(value>>5)&63;imm=imm-64 if imm>=32 else imm
        for svl in (16,32,64,256):
            vm=VM(be);vm.write(SVL,svl);vm.set('x0',0xfeedface)
            vm.run(ops)
            if rd!=31:assert vm.get('x'+str(rd))==(svl*imm)&((1<<64)-1)
            else:assert vm.get('x0')==0xfeedface
            count+=1
    if value&0xffdffc1f==0xe11f8000:
        store=bool(value&(1<<21));rn=(value>>5)&31;address=0x2000
        vm=VM(be);vm.write(('register',8,8) if rn==31 else vm.regnode('x'+str(rn)),address)
        original=int.from_bytes(bytes((i*17+3)&255 for i in range(64)),'little')
        vm.write(ZT0,original if store else 0)
        vm.write(('ram',address,64),0 if store else original)
        for op,out,ins in ops:
            if op=='LOAD':vm.write(out,vm.read(('ram',vm.read(ins[1]),out[2])))
            elif op=='STORE':vm.write(('ram',vm.read(ins[1]),ins[2][2]),vm.read(ins[2]))
            else:vm.run([(op,out,ins)])
        assert vm.read(('ram',address,64) if store else ZT0)==original
        count+=1
    return count

def check_svcr_bits(word,ops,be):
    """Check the modelled bit update only; ZA/streaming side effects remain opaque."""
    value=int(word,16)
    if value & 0xfffff8ff != 0xd503407f:return 0
    mask=(value>>9)&3;enable=(value>>8)&1
    svcr=('register',0x1768,8)
    for before in (0,1,2,3,0x100,0x101,0x102,0x103):
        vm=VM(be);vm.write(svcr,before)
        for op,out,ins in ops:
            if op=='CALLOTHER':break
            vm.run([(op,out,ins)])
        assert vm.read(svcr)==((before|mask) if enable else (before&~mask))
    return 8

def check_effects(word,ops):
    value=int(word,16)
    outputs={out for op,out,ins in ops if out is not None}
    calls=[(out,ins) for op,out,ins in ops if op=='CALLOTHER']
    if value&0xfffc0c00==0xc0cc0000: # LUTI2 writes Z, not ZA.
        assert any(out and out[0]=='register' and out[1]==0x5000+(value&31)*32 for out,ins in calls)
        assert any(ZT0 in ins for out,ins in calls)
    elif value&0xffdffc1f==0xe11f8000:return
    elif value&0xfffff800==0x04bf5800:return
    elif value&0xfffff8ff==0xd503407f:
        assert ZA in outputs
    elif value>>24 in (0x80,0x81,0xc0,0xe0,0xe1):
        if value&0xff3f0200==0xc0020000 or value&0xffff0200==0xc0c30000: # tile-to-vector MOVA, including Q
            assert any(out and out[0]=='register' and out[1]==0x5000+(value&31)*32 for out,ins in calls)
        elif value&0x00200000 and value>>24 in (0xe0,0xe1): # stores retain memory-effect call
            assert any(out is None and ZA in ins for out,ins in calls)
        else:
            assert ZA in outputs, ('missing ZA clobber',word,outputs)
        assert calls, ('silent tile instruction',word)

def run(resources=RESOURCES,jobs=4,words=None):
    fixture=json.loads((Path(__file__).parent/'rx18_feature_vectors.json').read_text())
    byword={}
    for row in fixture['rows']:byword.setdefault(row['word'],[]).append(row)
    selected=set(byword)|set(fixture['reserved'])
    if words:selected &= set(words)
    started=time.monotonic();results=[]
    with tempfile.TemporaryDirectory() as scratch:
        tree=Path(scratch);languages=tree/LANGUAGES;languages.mkdir(parents=True)
        for name in VARIANTS.values():shutil.copyfile(resources/name,languages/name)
        def check(pair):
            variant,word=pair;result={'variant':variant,'word':word,'numericCases':0}
            try:
                text=lift(word,variant,tree,'disassemble');result['text']=text
                if word in fixture['reserved']:
                    assert text is None,('unexpected admission',word,text)
                    result['status']='still_fail_closed';return result
                if text is None:
                    result['status']='still_fail_closed'
                    if word not in fixture['expectedStillFailClosed']:result['error']='expected allocated fixture did not decode'
                    return result
                expected=byword[word][0]['expected']
                assert normal(text)==normal(expected),(text,expected)
                code=lift(word,variant,tree,'pcode');assert code is not None
                ops=parse(code);result['status']='decode_only' if any(op=='CALLOTHER' for op,_,_ in ops) else 'normal_path'
                check_effects(word,ops)
                result['numericCases']=check_numeric(word,ops,variant=='be')
                result['svcrBitCases']=check_svcr_bits(word,ops,variant=='be')
                result['pcode']=code
            except Exception as e:result['error']=repr(e)
            return result
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            results=list(pool.map(check,[(v,w) for v in VARIANTS for w in sorted(selected)]))
    summary={v:{s:sum(r.get('status')==s for r in results if r['variant']==v) for s in ('normal_path','decode_only','still_fail_closed')} for v in VARIANTS}
    original={r['word'] for r in fixture['rows'] if r['origin']=='rx18_checked_in'}
    rx18={v:{s:sum(r.get('status')==s and r['word'] in original for r in results if r['variant']==v) for s in ('normal_path','decode_only','still_fail_closed')} for v in VARIANTS}
    return {'scope':'bounded actual SLEIGH decode/pcode; not native provider or hardware acceptance','nativeAcceptance':'prepared_not_native_executed','jobs':jobs,'seconds':round(time.monotonic()-started,3),'summary':summary,'originalCheckedInRX18Words':len(original),'originalRX18Summary':rx18,'numericCases':sum(r['numericCases'] for r in results),'svcrBitCases':sum(r.get('svcrBitCases',0) for r in results),'failures':[r for r in results if 'error' in r],'results':results}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--report',type=Path,required=True);p.add_argument('--jobs',type=int,default=4);p.add_argument('--word',action='append');a=p.parse_args()
    report=run(jobs=a.jobs,words=a.word);a.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='results'},indent=2))
    raise SystemExit(bool(report['failures']))
