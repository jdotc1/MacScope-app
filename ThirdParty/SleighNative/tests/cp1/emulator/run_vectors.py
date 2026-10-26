#!/usr/bin/env python3
"""Execute the unchanged schema-4 cases through emitted p-code, once per case.

GATE is deliberately not PASS: this normal-path VM cannot certify architecture
access/exception semantics. No QEMU observations enter evaluation or comparison.
"""
from __future__ import annotations
import argparse,collections,hashlib,json,pathlib,re,subprocess,sys
from cp1_vm import parse
from cp1_fixtures import initialize,expected_state,compare_states
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'tooling'))
from decode_receipt import lift_batch,metrics

def main():
    p=argparse.ArgumentParser();p.add_argument('--fixture',required=True,type=pathlib.Path);p.add_argument('--lifter',required=True,type=pathlib.Path);p.add_argument('--sla',required=True,type=pathlib.Path);p.add_argument('--report',required=True,type=pathlib.Path);p.add_argument('--form',help='regular expression selecting catalogue forms');p.add_argument('--require-normal',action='store_true');p.add_argument('--decode-only',action='store_true');a=p.parse_args()
    source=json.loads(a.fixture.read_text());meta=json.loads(subprocess.check_output([str(a.lifter.resolve()),'metadata',str(a.sla.resolve())],text=True))
    if a.decode_only:
        cases=source['decode_only'];words=[int(c['base'],16) for c in cases];rows=lift_batch(a.lifter,a.sla,words,a.sla.parent/'AARCH64.pspec');results=[]
        for c,w,r in zip(cases,words,rows):
            m=metrics(r);opaque=not r['error'] and m['callotherCount']>0;unimpl=not r['pcode'] and 'not implemented in pcode' in r['error'];ok=r['decoded'] and (opaque or unimpl)
            results.append({'instruction':c['instruction'],'word':f'0x{w:08x}','verdict':'PASS' if ok else 'FAIL','scope':'decode-only recognition (opaque or explicit unimpl), not instruction semantics',**r,**m})
        report={'scope':'50 decode-only classes; PASS means recognized assembly plus opaque CALLOTHER or explicit unimpl, never semantic completion','counts':dict(collections.Counter(r['verdict'] for r in results)),'results':results}
    else:
        cases=source['vectors']+source['reserved_vectors']
        if a.form:cases=[c for c in cases if re.search(a.form,c['instruction'])]
        words=sorted({int(c['encoding'],16) for c in cases})
        rows=lift_batch(a.lifter,a.sla,words,a.sla.parent/'AARCH64.pspec');byword=dict(zip(words,rows));results=[]
        for number,c in enumerate(cases):
            w=int(c['encoding'],16);r=byword[w];m=metrics(r)
            result={'ordinal':number,'id':c['instruction']+'/'+c.get('id','reserved'),'fixtureID':c.get('id','reserved'),'instruction':c['instruction'],'word':f'0x{w:08x}','decoded':r['decoded'],'mnemonic':r['mnemonic'],'body':r['body'],**m}
            gate='outcome' in c['expected']
            if gate:
                result.update(verdict='GATE',reason='decode-only/unsupported access, feature or architectural exception semantics; not executed as normal completion',expected=c['expected'],decodeError=r['error'])
            elif not r['decoded'] or r['error']:
                result.update(verdict='FAIL' if a.require_normal else 'UNSUPPORTED',reason='allocated constructor did not lift',decodeError=r['error'],expected=c['expected'])
            else:
                try:
                    if m['intraInstructionBranchCount']:raise ValueError('intra-instruction branch violates CP1 contract')
                    if m['u64OverflowVarnodes']:raise ValueError('varnode range fails exporter u64 bound')
                    actual=initialize(c,be=meta['bigEndian'],spaces=meta['spaces']);expected=expected_state(c,actual)
                    actual.run(parse(r['pcode']))
                    diff=compare_states(c,actual,expected)
                    if diff:result.update(verdict='FAIL',reason='architectural state mismatch',differences=diff,expected=c['expected'])
                    else:result.update(verdict='PASS',scope='normal-path exact fixture state; not access or native acceptance',executedOps=actual.executed_ops)
                except NotImplementedError as e:result.update(verdict='FAIL' if a.require_normal else 'UNSUPPORTED',reason=str(e),expected=c['expected'])
                except Exception as e:result.update(verdict='FAIL',reason=type(e).__name__+': '+str(e),expected=c['expected'])
            results.append(result)
        counts={k:sum(r['verdict']==k for r in results) for k in ('PASS','FAIL','UNSUPPORTED','GATE')}
        family={f:{k:sum(r['instruction']==f and r['verdict']==k for r in results) for k in counts} for f in sorted({r['instruction'] for r in results})}
        report={'scope':'Actual SLEIGH normal-path p-code; gates are not semantic passes; not hardware/native XPC acceptance','caseCount':len(results),'counts':counts,'families':family,'results':results,'pcodeByWord':{f'0x{w:08x}':r for w,r in byword.items()}}
    report.update(fixtureSHA256=hashlib.sha256(a.fixture.read_bytes()).hexdigest(),slaSHA256=hashlib.sha256(a.sla.read_bytes()).hexdigest(),frontend=meta['frontend'])
    a.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ('families','results','pcodeByWord')},indent=2))
    raise SystemExit(bool(report['counts'].get('FAIL')))
if __name__=='__main__':main()
