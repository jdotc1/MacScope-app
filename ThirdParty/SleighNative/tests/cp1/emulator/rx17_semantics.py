#!/usr/bin/env python3
"""Bounded execution of actual vendored sleigh-lift output, not a hardware emulator.
Byte-addressed overlapping registers; relative intra-instruction branches. Unknown
operations fail closed. BF16 helpers, when selected, are explicitly contract tests.
"""
import argparse, hashlib, json, math, re, struct, subprocess
from pathlib import Path
VN = re.compile(r'\((\w+),(0x[0-9a-f]+),(\d+)\)')
SLA = {'le':'AARCH64.sla','be':'AARCH64BE.sla','apple':'AARCH64_AppleSilicon.sla'}
def signed(v,n): return v-(1<<(8*n)) if v&(1<<(8*n-1)) else v
def bits(v,n):
    try: raw=struct.pack('<'+{2:'e',4:'f',8:'d'}[n],v)
    except OverflowError: raw=struct.pack('<'+{2:'e',4:'f',8:'d'}[n],math.copysign(math.inf,v))
    return int.from_bytes(raw,'little')
def floating(v,n): return struct.unpack('<'+{2:'e',4:'f',8:'d'}[n],v.to_bytes(n,'little'))[0]
def parse(text):
    result=[]
    for line in text.splitlines():
        if not line.strip(): continue
        out=None
        if ' = ' in line:
            left,line=line.split(' = ',1); m=VN.fullmatch(left.strip()); assert m,left
            out=(m[1],int(m[2],16),int(m[3]))
        op=line.strip().split()[0]
        result.append((op,out,[(m[1],int(m[2],16),int(m[3])) for m in VN.finditer(line)]))
    return result
class VM:
    def __init__(self,be=False,helpers=None): self.be=be; self.mem={}; self.helpers=helpers or {}; self.calls=[]
    def read(self,v):
        sp,off,n=v
        if sp=='const': return off&((1<<(8*n))-1)
        return int.from_bytes(bytes(self.mem.get((sp,off+i),0) for i in range(n)), 'big' if self.be else 'little')
    def write(self,v,value):
        sp,off,n=v; assert sp!='const'
        raw=(value&((1<<(8*n))-1)).to_bytes(n,'big' if self.be else 'little')
        for i,b in enumerate(raw): self.mem[(sp,off+i)]=b
    def regnode(self,name):
        if name in ('NG','ZR','CY','OV'): return ('register',0x100+('NG','ZR','CY','OV').index(name),1)
        if name in ('fpcr','fpsr'): return ('register',0x1038 if name=='fpcr' else 0x1040,8)
        m=re.fullmatch(r'([xqds hz])(\d+)',name.replace(' ',''))
        if not m: raise KeyError(name)
        kind,index=m[1],int(m[2]); n={'x':8,'q':16,'d':8,'s':4,'h':2,'z':32}[kind]
        off=0x4000+index*8 if kind=='x' else 0x5000+index*32+(32-n if self.be else 0)
        return ('register',off,n)
    def set(self,name,v): self.write(self.regnode(name),v)
    def get(self,name): return self.read(self.regnode(name))
    def run(self,ops):
        pc=steps=0
        while pc<len(ops):
            steps+=1
            if steps>10000: raise RuntimeError('pcode loop limit')
            op,out,ins=ops[pc]; a=[self.read(v) for v in ins]; sz=[v[2] for v in ins]; jump=1
            if op in ('BRANCH','CBRANCH'):
                assert ins[0][0]=='const','External branch outside harness scope'
                if op=='BRANCH' or a[1]: jump=signed(a[0],sz[0])
                pc+=jump; continue
            if op=='IMARK': pc+=1; continue
            if op in ('COPY','INT_ZEXT'): r=a[0]
            elif op=='INT_SEXT': r=signed(a[0],sz[0])
            elif op=='INT_ADD': r=a[0]+a[1]
            elif op=='INT_SUB': r=a[0]-a[1]
            elif op=='INT_MULT': r=a[0]*a[1]
            elif op in ('INT_AND','BOOL_AND'): r=a[0]&a[1]
            elif op in ('INT_OR','BOOL_OR'): r=a[0]|a[1]
            elif op in ('INT_XOR','BOOL_XOR'): r=a[0]^a[1]
            elif op=='INT_LEFT': r=0 if a[1]>=8*out[2] else a[0]<<a[1]
            elif op=='INT_RIGHT': r=a[0]>>min(a[1],8*sz[0])
            elif op=='INT_SRIGHT': r=signed(a[0],sz[0])>>min(a[1],8*sz[0])
            elif op=='INT_EQUAL': r=int(a[0]==a[1])
            elif op=='INT_NOTEQUAL': r=int(a[0]!=a[1])
            elif op=='INT_LESS': r=int(a[0]<a[1])
            elif op=='INT_LESSEQUAL': r=int(a[0]<=a[1])
            elif op=='INT_SLESS': r=int(signed(a[0],sz[0])<signed(a[1],sz[1]))
            elif op=='INT_SLESSEQUAL': r=int(signed(a[0],sz[0])<=signed(a[1],sz[1]))
            elif op=='INT_2COMP': r=-a[0]
            elif op=='INT_NEGATE': r=~a[0]
            elif op=='BOOL_NEGATE': r=int(not a[0])
            elif op=='POPCOUNT': r=bin(a[0]).count('1')  # int.bit_count needs 3.10; repo floor is 3.9
            elif op=='LZCOUNT': r=sz[0]*8-a[0].bit_length()
            elif op=='SUBPIECE': r=a[0]>>(8*a[1])
            elif op=='PIECE': r=(a[0]<<(8*sz[1]))|a[1]
            elif op in ('FLOAT_FLOAT2FLOAT','FLOAT2FLOAT'): r=bits(floating(a[0],sz[0]),out[2])
            elif op in ('FLOAT_INT2FLOAT','INT2FLOAT'): r=bits(float(signed(a[0],sz[0])),out[2])
            elif op in ('FLOAT_TRUNC','TRUNC'): r=int(floating(a[0],sz[0]))
            elif op in ('FLOAT_ADD','FLOAT_SUB','FLOAT_MULT','FLOAT_DIV'):
                x,y=floating(a[0],sz[0]),floating(a[1],sz[1])
                r=bits({'FLOAT_ADD':lambda:x+y,'FLOAT_SUB':lambda:x-y,'FLOAT_MULT':lambda:x*y,'FLOAT_DIV':lambda:x/y}[op](),out[2])
            elif op=='FLOAT_NEG': r=a[0]^(1<<(sz[0]*8-1))
            elif op=='FLOAT_ABS': r=a[0]&((1<<(sz[0]*8-1))-1)
            elif op=='CALLOTHER':
                self.calls.append((a[0],a[1:]))
                if a[0] not in self.helpers: raise NotImplementedError(f'CALLOTHER {a[0]}')
                r=self.helpers[a[0]](a[1:],sz[1:],out)
            else: raise NotImplementedError(op)
            if out is not None: self.write(out,r)
            pc+=1
class Lifter:
    def __init__(self,args,variant): self.args=args; self.variant=variant; self.cache={}
    def get(self,word):
        if word not in self.cache:
            cmd=[str(self.args.lifter),'pcode',SLA[self.variant],word.to_bytes(4,'little').hex(),'-p',str(self.args.tree)]
            if self.args.pspec: cmd+=['-s',str(self.args.pspec)]
            p=subprocess.run(cmd,cwd=self.args.languages,capture_output=True,text=True,timeout=60)
            if p.returncode: raise RuntimeError(f'{word:08x}: rc={p.returncode} {p.stderr}')
            self.cache[word]=parse(p.stdout)
        return self.cache[word]
def fj_oracle(raw,fpcr,fpsr):
    fz=bool(fpcr&(1<<24)) and not bool(fpcr&2); fiz=bool(fpcr&1)
    sign=raw>>63; exp=(raw>>52)&2047; frac=raw&((1<<52)-1)
    if exp==2047: return 0,0,fpsr|1
    if exp==0 and frac and (fz or fiz): return 0,0,fpsr|(128 if fz else 0)
    mant=frac|((1<<52) if exp else 0); shift=(exp-1023 if exp else -1022)-52
    mag=mant<<shift if shift>=0 else mant>>(-shift)
    fractional=bool(mant&((1<<min(-shift,1074))-1)) if shift<0 else False
    value=-mag if sign else mag
    overflow=not(-2**31<=value<2**31)
    exact=not fractional and not overflow and not(raw==1<<63)
    # Invalid conversion suppresses IXC; non-overflow fractional conversion sets IXC.
    flags=1 if overflow else (16 if fractional else 0)
    return value&0xffffffff,int(exact),fpsr|flags

def exception_contract(values,sizes,out):
    assert sizes==[8,8,8] and out[2]==8,(sizes,out)
    exc,fpcr,old=values
    assert not(fpcr&0x9f00),'Enabled traps outside harness normal-path contract'
    return old|exc

def test_fj(lift,be):
    raws=[bits(v,8) for v in (0.,-0.,1.,-1.,1.5,-1.5,-2.**31,2.**31,2.**32+1,math.inf,-math.inf)]
    raws += [0x7ff8000000000123,0x7ff0000000000123,1,0x8000000000000001,0x000fffffffffffff]
    count=0
    for rd in (0,31):
      ops=lift.get(0x1e7e0020|rd)
      for raw in raws:
       for fpcr in (0,1<<24,2,1,3,(1<<24)|2):
        for old in (0,0x0800000e):
         vm=VM(be,{ins[0][1]:exception_contract for op,out,ins in ops if op=='CALLOTHER'}); vm.set('d1',raw); vm.set('x0',0xfeedfacecafebabe); vm.set('fpcr',fpcr); vm.set('fpsr',old)
         for name in ('NG','ZR','CY','OV'): vm.set(name,1)
         vm.run(ops); result,z,status=fj_oracle(raw,fpcr,old)
         actual=(vm.get('x0'),*[vm.get(n) for n in ('NG','ZR','CY','OV')],vm.get('fpsr'))
         want=(result if rd==0 else 0xfeedfacecafebabe,0,z,0,0,status)
         assert actual==want,('FJCVTZS',hex(raw),fpcr,rd,actual,want)
         count+=1
    return count

def main():
    p=argparse.ArgumentParser(); p.add_argument('--tree',type=Path,required=True); p.add_argument('--languages',type=Path); p.add_argument('--lifter',type=Path,required=True); p.add_argument('--pspec',type=Path); p.add_argument('--variant',choices=list(SLA),action='append'); p.add_argument('--suite',choices=['fj','fhm','bf16','all'],default='all'); p.add_argument('--report',type=Path,required=True)
    a=p.parse_args(); a.languages=a.languages or a.tree/'Ghidra/Processors/AARCH64/data/languages'; report={'scope':'Vendored lifter p-code execution; not native app or hardware acceptance','variants':{}}
    for variant in a.variant or ['le','be','apple']:
        l=Lifter(a,variant); row={}; report['variants'][variant]=row
        for name,fn in [('fj',test_fj),('fhm',test_fhm),('bf16',test_bf16)]:
            if a.suite in (name,'all'):
                try: row[name]={'passed':fn(l,variant=='be')}
                except Exception as e: row[name]={'error':repr(e)}
        row['sla_sha256']=hashlib.sha256((a.languages/SLA[variant]).read_bytes()).hexdigest()
    a.report.write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report,indent=2))
    if any('error' in value for row in report['variants'].values() for value in row.values() if isinstance(value,dict)): raise SystemExit(1)

def lane(value,index,n): return (value>>(index*n*8))&((1<<(n*8))-1)
def pack(values,n): return sum(v<<(i*n*8) for i,v in enumerate(values))
def test_fhm(lift,be):
    count=0
    for q in (0,1):
     lanes=2<<q
     for part in (0,1):
      for sub in (0,1):
       for index in (None,0,1,2,3,4,5,6,7):
        for rd,rn,rm in ((0,1,2),(1,1,2),(2,1,2),(0,1,1)):
         base=(0x0e20ec00 if part==0 else 0x2e20cc00) if index is None else (0x0f800000 if part==0 else 0x2f808000)
         word=base|(q<<30)|(sub<<23 if index is None else sub<<14)|rd|(rn<<5)|(rm<<16)
         if index is not None: word|=((index>>2)<<11)|(((index>>1)&1)<<21)|((index&1)<<20)
         for large in (False,True):
          vm=VM(be)
          for r in (0,1,2): vm.set('z'+str(r),(1<<256)-1)
          vm.set('q0',pack([bits(v,4) for v in (2.,-4.,8.,-16.)],4))
          vm.set('q1',pack([bits(v,2) for v in ((65504.,)*8 if large else (1.,2.,3.,4.,5.,6.,7.,8.))],2))
          vm.set('q2',pack([bits(v,2) for v in ((65504.,)*8 if large else (2.,-3.,4.,-5.,6.,-7.,8.,-9.))],2))
          old={r:vm.get('q'+str(r)) for r in (0,1,2)}
          expected=[]
          for e in range(lanes):
           a=floating(lane(old[rn],e+part*lanes,2),2)
           b=floating(lane(old[rm],index if index is not None else e+part*lanes,2),2)
           accum=floating(lane(old[rd],e,4),4)
           # Binary16 products have <=22 significant bits, so finite product is exact in binary32.
           expected.append(bits(accum+(-1 if sub else 1)*a*b,4))
          vm.run(lift.get(word)); actual=vm.get('z'+str(rd)); want=pack(expected,4)
          assert actual==want,('FHM',hex(word),q,part,sub,index,(rd,rn,rm),large,hex(actual),hex(want))
          count+=1
    return count

def bf16_rne(raw):
    # Contract oracle only. Architectural FPCR alternatives/exceptions require host implementation.
    exp=raw&0x7f800000; frac=raw&0x7fffff
    if exp==0x7f800000 and frac: return (raw>>16)|0x40
    return ((raw+0x7fff+((raw>>16)&1))>>16)&0xffff

def bf16_oracle(raw,fpcr,old):
    sign=raw>>31; exp=(raw>>23)&255; frac=raw&0x7fffff
    ah=bool(fpcr&2); fz=bool(fpcr&(1<<24)) or ah; fiz=bool(fpcr&1) or ah; dn=bool(fpcr&(1<<25)); mode=0 if ah else (fpcr>>22)&3
    if exp==255:
        if not frac: return raw>>16,old
        invalid=not bool(frac&(1<<22))
        return ((0xffc0 if ah else 0x7fc0) if dn else ((raw>>16)|0x40)),old|(int(invalid) if not ah else 0)
    if exp==0 and frac and (fz or fiz): return sign<<15,old|(128 if fz and not ah else 0)
    high=raw>>16; low=raw&65535; exc=16 if low else 0
    increment=(low>32768 or (low==32768 and high&1)) if mode==0 else ((not sign and low!=0) if mode==1 else ((sign and low!=0) if mode==2 else False))
    result=(high+int(increment))&65535
    if (result&0x7f80)==0x7f80 and exp!=255: exc|=4|16
    if exp==0 and low: exc|=8
    if fz and (result&0x7f80)==0 and (result&127): result=sign<<15; exc|=8
    return result,old|(exc if not ah else 0)

def test_bf16(lift,be):
    values=[0,0x80000000,0x3f800000,0x3f808000,0x3f818000,0xbf808001,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7fc12345,0x7f812345,1,0x007fffff,0x00800000,0x3f800001]
    count=0
    for form in ('scalar','narrow','narrow2'):
     for rd,rn in ((0,1),(1,1)):
      word=({'scalar':0x1e634000,'narrow':0x0ea16800,'narrow2':0x4ea16800}[form])|rd|(rn<<5)
      ops=lift.get(word)
      helpers={ins[0][1]:exception_contract for op,out,ins in ops if op=='CALLOTHER'}
      for mode in range(4):
       for ctrl in (0,1<<24,1,2,(1<<24)|2,1<<25,(1<<25)|2,4,6):
        fpcr=ctrl|(mode<<22)
        for index in range(len(values)):
         vm=VM(be,helpers)
         vm.set('z0',(1<<256)-1); vm.set('z1',(1<<256)-1)
         vm.set('q0',0x123456789abcdef00fedcba987654321)
         inputs=[values[(index+j)%len(values)] for j in range(4)]
         vm.set('q'+str(rn),pack(inputs,4)); olddest=vm.get('q'+str(rd)); old=0x08000002; vm.set('fpsr',old); vm.set('fpcr',fpcr)
         wanted=[]; status=old
         for raw in inputs[:1 if form=='scalar' else 4]:
          val,status=bf16_oracle(raw,fpcr,status); wanted.append(val)
         result=pack(wanted,2)
         if form=='narrow2': result=(result<<64)|(olddest&((1<<64)-1))
         if form=='scalar' and fpcr&4: result|=pack(inputs,4)&~65535
         vm.run(ops)
         actual=(vm.get('z'+str(rd)),vm.get('fpsr')); want=(result,status)
         assert actual==want,('BF16',form,rd,rn,hex(fpcr),[hex(x) for x in inputs],tuple(hex(x) for x in actual),tuple(hex(x) for x in want))
         count+=1
    return count

if __name__=='__main__': main()
