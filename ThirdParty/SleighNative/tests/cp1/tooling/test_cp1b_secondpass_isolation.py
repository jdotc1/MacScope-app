#!/usr/bin/env python3
"""Check only three vertical MOVA bodies changed; preserve all prior CP1 displays.

Every original source constructor is checked. Compiled coverage is all specialized
instruction constructors plus free-field sweeps and fixture words, not all words.
Unchanged instructions use the first-pass strict unique-alpha comparator, including
read-before-write and cross-pool overlap checks. Changed MOVA bodies are instead
covered by the independent full-state and write-address tests.
"""
import argparse,hashlib,json,pathlib,re
from test_cp1b_display import constructors,fixed_pattern,FIELD,compare_pcode,comparator_selftest,error_class,check_unique_initialized
from decode_receipt import VARIANTS,lift_batch,metrics

def main():
 p=argparse.ArgumentParser()
 for x in ['before','after','fixture','samples','lifter','report']:p.add_argument('--'+x,required=True,type=pathlib.Path)
 a=p.parse_args();old=constructors(a.before/'AARCH64sme_cp1.sinc');new=constructors(a.after/'AARCH64sme_cp1.sinc')
 helpers=[x for x in new if x[0].startswith('CP1Mova')];new=[x for x in new if not x[0].startswith('CP1Mova')]
 assert len(old)==len(new)
 words=set();coverage=[];changed=[]
 for ordinal,(x,y) in enumerate(zip(old,new)):
  assert x[0]==y[0],('display source changed',ordinal)
  stripped=re.sub(r'\s*&\s*CP1Mova\w+','',y[1]);assert x[1]==stripped,('pattern changed',ordinal)
  base,mask=fixed_pattern(x[1])
  if x[2]!=y[2]:
   assert x[0].startswith(':') and base&0xffdf8000 in (0xc0008000,0xc0408000,0xc0808000),('unexpected body change',ordinal,hex(base))
   changed.append({'ordinal':ordinal,'base':base,'mask':mask,'beforeSHA256':hashlib.sha256(x[2].encode()).hexdigest(),'afterSHA256':hashlib.sha256(y[2].encode()).hexdigest()})
  if not x[0].startswith(':'):continue
  cases={base,base|(~mask&0xffffffff)}
  for lo,width in set(FIELD.findall(x[1])):
   lo,width=int(lo),int(width)
   if width>5:continue
   part=((1<<width)-1)<<lo
   for v in range(1<<width):
    w=(base&~part)|(v<<lo)
    if w&mask==base:cases.add(w)
  words.update(cases);coverage.append({'ordinal':ordinal,'base':base,'mask':mask,'words':len(cases)})
 assert len(changed)==3
 fixed_sources={}
 for name in ['AARCH64instructions.sinc','AARCH64sme_core.sinc','AARCH64.pspec']:
  b=(a.before/name).read_bytes();assert b==(a.after/name).read_bytes();fixed_sources[name]=hashlib.sha256(b).hexdigest()
 fixture=json.loads(a.fixture.read_text());words.update(int(x['encoding'],16) for key in ('vectors','reserved_vectors') for x in fixture[key]);words.update(int(x['base'],16) for x in fixture['decode_only']);words.update(int(x['word'],16) for x in json.loads(a.samples.read_text())['fixtures'])
 words=sorted(words);rows=[];examples={}
 for variant,fn in VARIANTS.items():
  for start in range(0,len(words),48):
   batch=words[start:start+48];bs=lift_batch(a.lifter,a.before/fn,batch,a.before/'AARCH64.pspec');ns=lift_batch(a.lifter,a.after/fn,batch,a.after/'AARCH64.pspec')
   for w,b,n in zip(batch,bs,ns):
    assert (b['mnemonic'],b['body'],b['decoded'],error_class(b))==(n['mnemonic'],n['body'],n['decoded'],error_class(n)),('display/decode changed',variant,hex(w))
    target=any(w&x['mask']==x['base'] for x in changed)
    stat=metrics(n);cp1=any(w&x['mask']==x['base'] for x in coverage)
    if cp1 and n['decoded'] and not n['error']:assert stat['intraInstructionBranchCount']==0
    if target:
     check_unique_initialized(n['pcode']);raw=False;delta=None
     assert not re.search(r'\b(CALLOTHER|BRANCH|CBRANCH|BRANCHIND|CALL|CALLIND|RETURN)\b',n['pcode'])
    else:
     raw,delta,_,_=compare_pcode(b['pcode'],n['pcode'],True)
     if not raw and variant not in examples:examples[variant]={'word':hex(w),'before':b['pcode'],'after':n['pcode'],'uniqueDelta':delta}
    rows.append({'variant':variant,'word':f'{w:08x}','changedMova':target,'rawIdentical':raw,'uniqueDelta':delta,'display':n['mnemonic']+' '+n['body'],'beforeSHA256':hashlib.sha256(b['pcode'].encode()).hexdigest(),'afterSHA256':hashlib.sha256(n['pcode'].encode()).hexdigest(),**stat})
  print(variant,len(words),'display/isolation comparisons passed',flush=True)
 result={'scope':__doc__,'sourceConstructorsCompared':len(old),'newPureHelpers':len(helpers),'changedBodies':changed,'specializedInstructionConstructors':len(coverage),'wordsPerVariant':len(words),'compiledComparisons':len(rows),'changedMovaComparisons':sum(x['changedMova'] for x in rows),'unchangedPcodeComparisons':sum(not x['changedMova'] for x in rows),'fixedSources':fixed_sources,'negativeComparatorTests':comparator_selftest(),'rawRebaseExamples':examples,'constructorCoverage':coverage,'rows':rows}
 a.report.write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k not in ('rows','constructorCoverage','rawRebaseExamples','scope')})
if __name__=='__main__':main()
