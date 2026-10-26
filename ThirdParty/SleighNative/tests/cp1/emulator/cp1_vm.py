#!/usr/bin/env python3
"""CP1 bounded p-code VM extension, not an instruction-semantic oracle.

All instruction effects come from supplied raw p-code. This module never inspects
an instruction word or a fixture expected value. Architectural register aliases
and byte-addressed storage are explicit and independent of the SLEIGH generator.
"""
from __future__ import annotations
import re
from rx17_semantics import VM,parse,signed

SCALARS={'SVCR':(0x1768,8),'SVL_BYTES':(0x7000,8),'NONSTREAM_VL_BYTES':(0x7080,8),
         'FPMR':(0x7088,8),'FPMR_PRESENT':(0x7090,8),'ZA_VALID':(0x7098,8),
         'ZT0_VALID':(0x70a0,8),'SME2_PRESENT':(0x70a8,8),'FFR':(0x70c0,32),
         'ZT0':(0x7040,64),'FPCR':(0x1038,8),'FPSR':(0x1040,8),'SP':(8,8)}
class SMEVM(VM):
    def __init__(self,be=False,helpers=None,spaces=None,max_steps=500000):
        super().__init__(be,helpers)
        self.spaces={int(k):v for k,v in (spaces or {}).items()}
        self.max_steps=max_steps;self.memory_accesses=[];self.mapped_ranges=None
        self.first_access_fault=None;self.executed_ops=0
    @staticmethod
    def bounded(v):
        sp,off,size=v
        if not isinstance(off,int) or not isinstance(size,int) or off<0 or size<=0 or off+size>2**64-1:
            raise ValueError(f'varnode storage range overflows u64: {v}')
        if sp=='register' and off+size>0x30000:raise ValueError(f'out-of-model register range: {v}')
    def read(self,v):
        self.bounded(v);return super().read(v)
    def write(self,v,value):
        self.bounded(v);return super().write(v,value)
    def get(self,name):
        u=name.upper()
        if u in ('XZR','WZR'):return 0
        if u in ('SM','ZA'):return (self.get('SVCR')>>(u=='ZA'))&1
        if u=='NZCV':return ''.join(str(super(SMEVM,self).get(n)&1) for n in ('NG','ZR','CY','OV'))
        m=re.fullmatch(r'(Z|PN|P)(\d+)',u)
        if m:
            typ,i=m[1],int(m[2]);limit=32 if typ=='Z' else 16
            if i>=limit:raise KeyError(name)
            if typ=='Z':return self.read(('register',0x5000+i*32,32))|(self.read(('register',0x10000+i*224,224))<<256)
            return self.read(('register',0x6000+i*4,4))|(self.read(('register',0x12000+i*28,28))<<32)
        if u in SCALARS:return self.read(('register',*SCALARS[u]))
        m=re.fullmatch(r'W(\d+)',u)
        if m:return super().get('x'+m[1])&0xffffffff
        return super().get(name.lower() if u not in ('NG','ZR','CY','OV') else u)
    def set(self,name,value):
        u=name.upper()
        if u in ('XZR','WZR'):return
        if u in ('SM','ZA'):
            bit=int(u=='ZA');self.set('SVCR',(self.get('SVCR')&~(1<<bit))|((int(value)&1)<<bit));return
        if u=='NZCV':
            bits=value if isinstance(value,str) else f'{value&15:04b}'
            if len(bits)!=4 or any(b not in '01' for b in bits):raise ValueError('NZCV must be four binary digits')
            for k,b in zip(('NG','ZR','CY','OV'),bits):super().set(k,int(b))
            return
        m=re.fullmatch(r'(Z|PN|P)(\d+)',u)
        if m:
            typ,i=m[1],int(m[2]);limit=32 if typ=='Z' else 16
            if i>=limit:raise KeyError(name)
            if typ=='Z':
                self.write(('register',0x5000+i*32,32),value);self.write(('register',0x10000+i*224,224),value>>256)
            else:
                self.write(('register',0x6000+i*4,4),value);self.write(('register',0x12000+i*28,28),value>>32)
            return
        if u in SCALARS:self.write(('register',*SCALARS[u]),value);return
        m=re.fullmatch(r'W(\d+)',u)
        if m:super().set('x'+m[1],value&0xffffffff);return
        super().set(name.lower() if u not in ('NG','ZR','CY','OV') else u,value)
    @staticmethod
    def za_cell_node(tile,esize,row,col):
        b=esize//8
        if esize not in (8,16,32,64,128) or not 0<=tile<b or min(row,col)<0 or row*b>=256 or (col+1)*b>256:
            raise ValueError('ZA tile coordinate outside maximum architecture')
        return ('register',0x20000+(tile+row*b)*256+col*b,b)
    def write_za_cell(self,tile,esize,row,col,value):self.write(self.za_cell_node(tile,esize,row,col),value)
    def read_za_cell(self,tile,esize,row,col):return self.read(self.za_cell_node(tile,esize,row,col))
    def _access(self,space,off,size,store=False):
        node=(space,off,size);self.bounded(node)
        if space=='ram':
            if self.first_access_fault and not self.memory_accesses:raise NotImplementedError('abstract memory fault: '+self.first_access_fault)
            if self.mapped_ranges is not None and not any(lo<=off and off+size<=hi for lo,hi in self.mapped_ranges):
                raise MemoryError(f'unmapped architectural Mem access at {off:#x}+{size}')
            self.memory_accesses.append({'address':off,'size':size,'kind':'store' if store else 'load'})
        return node
    def run(self,ops):
        pc=0
        while 0<=pc<len(ops):
            self.executed_ops+=1
            if self.executed_ops>self.max_steps:raise RuntimeError('bounded pcode step limit')
            op,out,ins=ops[pc]
            for v in ([out] if out else [])+ins:self.bounded(v)
            if op in ('BRANCH','CBRANCH'):
                if not ins or ins[0][0]!='const':raise NotImplementedError('external pcode branch')
                take=op=='BRANCH' or self.read(ins[1])!=0
                dest=pc+(signed(self.read(ins[0]),ins[0][2]) if take else 1)
                if not 0<=dest<=len(ops):raise ValueError('relative branch escapes instruction')
                pc=dest;continue
            if op in ('LOAD','STORE'):
                idx=self.read(ins[0])
                if idx not in self.spaces:raise NotImplementedError(f'unknown pcode address-space ID {idx}')
                space=self.spaces[idx]
                if space not in ('register','ram','unique'):raise NotImplementedError('memory space '+space)
                addr=self.read(ins[1]);size=out[2] if op=='LOAD' else ins[2][2]
                node=self._access(space,addr,size,op=='STORE')
                if op=='LOAD':self.write(out,self.read(node))
                else:self.write(node,self.read(ins[2]))
            elif op in ('INT_DIV','INT_REM','INT_SDIV','INT_SREM'):
                a,b=(self.read(v) for v in ins)
                if op in ('INT_SDIV','INT_SREM'):a,b=signed(a,ins[0][2]),signed(b,ins[1][2])
                if b==0:raise ZeroDivisionError('pcode integer divisor is zero')
                q=(abs(a)//abs(b))*(-1 if (a<0)!=(b<0) else 1)
                self.write(out,q if op in ('INT_DIV','INT_SDIV') else a-q*b)
            elif op in ('INT_CARRY','INT_SCARRY','INT_SBORROW'):
                a,b=(self.read(v) for v in ins);n=8*ins[0][2]
                if op=='INT_CARRY':r=a+b>=1<<n
                else:
                    a,b=signed(a,ins[0][2]),signed(b,ins[1][2]);s=a+b if op=='INT_SCARRY' else a-b;r=not -(1<<(n-1))<=s<(1<<(n-1))
                self.write(out,int(r))
            else:super().run([(op,out,ins)])
            pc+=1
