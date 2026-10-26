#!/usr/bin/env python3
"""Deterministic SLEIGH source generator. Reads encoding catalogue ONLY.

No vector IDs, inputs, expected results or QEMU observations are consumed.
Every loop below expands at generation time; generated instructions contain
straight-line p-code, not relative branches. See DESIGN.md for storage ABI.
"""
from __future__ import annotations
import argparse,json,pathlib,math,re
FIELDS=set();CORE=[];CON=[];IMPLEMENTED=[]
def f(lo,w):FIELDS.add((lo,w));return f'cp1_f{lo}_{w}'
def emit(s):CON.append(s.strip()+'\n')
def macro(s):CORE.append(s.strip()+'\n')
def pattern(c,extra=None,using=()):
    mask=int(c['encoding']['mask'],16);base=int(c['encoding']['base'],16)
    for lo,w,val in extra or []:
        m=((1<<w)-1)<<lo
        if (base^val<<lo)&mask&m:raise ValueError('specialization contradicts fixed encoding')
        mask|=m;base=(base&~m)|(val<<lo)
    terms=[];n=0
    while n<32:
        if not(mask>>n&1):n+=1;continue
        j=n
        while j<32 and mask>>j&1:j+=1
        terms.append(f'{f(n,j-n)}=0x{(base>>n)&((1<<(j-n))-1):x}');n=j
    return ' & '.join(terms+list(dict.fromkeys(using)))
def ctor(c,display,body,extra=None,using=()):
    emit(f'# {c["instruction"]}; {c["sources"]["arm_xml"]}\n:{display}\nis {pattern(c,extra,using)} {{\n{body}\n}}')
def const_repeat(var,nbytes,seed):
    lines=[f'local {var}:{nbytes} = 0x{seed:x};'];shift=64
    while shift<8*nbytes:lines.append(f'{var} = ({var} << {shift}) | {var};');shift*=2
    return '\n'.join(lines)
def low_mask(var,nbytes,bits):return f'local {var}:{nbytes} = 1; {var} = ({var} << ({bits})) - 1;'
def stride(var,nbytes,b,bits):
    if b==1:return low_mask(var,nbytes,bits)
    return const_repeat(var,nbytes,sum(1<<n for n in range(0,64,b)))
def pwrite(value,index):return f'cp1_write_p({value}, {index});'

def build_core():
    macro('''# Bounded scalable extension ABI. Legacy Z/P low storage and Q aliases stay fixed.
define register offset=0x10000 size=224 [ '''+' '.join(f'cp1_zh{i}' for i in range(32))+''' ];
define register offset=0x12000 size=28 [ '''+' '.join(f'cp1_ph{i}' for i in range(16))+''' ];
define register offset=0x7080 size=8 [ cp1_nonstream_vl_bytes cp1_fpmr cp1_fpmr_present cp1_za_valid cp1_zt0_valid cp1_sme2_present ];
define register offset=0x70c0 size=32 [ cp1_ffr ];
define register offset=0x20000 size=256 [ '''+' '.join(f'cp1_za_r{i}' for i in range(256))+''' ];

macro cp1_current_bytes(out) {
 local sm:8 = svcr & 1;
 out = sme_svl_bytes * sm + cp1_nonstream_vl_bytes * (1-sm);
}
macro cp1_read_z(out,idx) {
 local loaddr:4 = 0x5000 + idx*32;
 local hiaddr:4 = 0x10000 + idx*224;
 local low:32 = *[register]:32 loaddr;
 local high:224 = *[register]:224 hiaddr;
 local ext:256 = zext(high);
 out = (ext << 256) | zext(low);
}
macro cp1_write_z(value,idx) {
 local loaddr:4 = 0x5000 + idx*32;
 local hiaddr:4 = 0x10000 + idx*224;
 *[register]:32 loaddr = value:32;
 local high:224 = value(32);
 *[register]:224 hiaddr = high;
}
macro cp1_read_p(out,idx) {
 local loaddr:4 = 0x6000 + idx*4;
 local hiaddr:4 = 0x12000 + idx*28;
 local low:4 = *[register]:4 loaddr;
 local high:28 = *[register]:28 hiaddr;
 local ext:32 = zext(high);
 out = (ext << 32) | zext(low);
}
macro cp1_write_p(value,idx) {
 local loaddr:4 = 0x6000 + idx*4;
 local hiaddr:4 = 0x12000 + idx*28;
 *[register]:4 loaddr = value:4;
 local high:28 = value(4);
 *[register]:28 hiaddr = high;
}
macro cp1_read_w(out,idx) {
@if DATA_ENDIAN == "little"
 local ptr:4 = 0x4000 + idx*8;
@else
 local ptr:4 = 0x4004 + idx*8;
@endif
 out = *[register]:4 ptr;
}
''')
    # Dynamic reset masks avoid immediate complemented-u64 range overflow.
    reset=['''macro cp1_transition(selectsm,selectza,enable) {
 local oldsm:8 = svcr & 1;
 local oldza:8 = (svcr >> 1) & 1;
 local newsm:8 = oldsm*(1-selectsm)+enable*selectsm;
 local newza:8 = oldza*(1-selectza)+enable*selectza;
 local smchange:1 = oldsm != newsm;
 local zachange:1 = oldza != newza;
 local smkeep:32 = zext(!smchange); smkeep = 0-smkeep;
 local zhkeep:224 = zext(!smchange); zhkeep = 0-zhkeep;
 local phkeep:28 = zext(!smchange); phkeep = 0-phkeep;
''']
    for i in range(32):reset.append(f'z{i} = z{i} & smkeep; cp1_zh{i} = cp1_zh{i} & zhkeep;')
    for i in range(16):reset.append(f'p{i} = p{i} & smkeep:4; cp1_ph{i} = cp1_ph{i} & phkeep;')
    reset+=['''cp1_ffr = cp1_ffr & smkeep;
 fpsr = fpsr*zext(!smchange) + 0x0800009f*zext(smchange);
 cp1_fpmr = cp1_fpmr*zext((!smchange) || (cp1_fpmr_present==0));
 local clearza:1 = zachange && (newza != 0);
 local zakeep:256 = zext(!clearza); zakeep = 0-zakeep;
''']
    reset += [f'cp1_za_r{i} = cp1_za_r{i} & zakeep;' for i in range(256)]
    reset+=['''local ztchange:1 = zachange && (cp1_sme2_present!=0);
 local clearzt:1 = ztchange && (newza != 0);
 local ztkeep:64 = zext(!clearzt); ztkeep = 0-ztkeep;
 zt0 = zt0 & ztkeep;
 cp1_za_valid = cp1_za_valid*zext(!zachange) + newza*zext(zachange);
 cp1_zt0_valid = cp1_zt0_valid*zext(!ztchange) + newza*zext(ztchange);
 svcr = ((svcr >> 2) << 2) | newsm | (newza << 1);
}'''];macro('\n'.join(reset))
    # Four-vector expansion fits 128 bytes even at SVL=2048 bits.
    lines=['''macro cp1_counter_expand(out,raw,current) {
 local tag:8 = zext(raw:2) & 15;
 local b:8 = tag & (0-tag); b = b | zext(b==0);
 local bound:8 = current*4;
 local k:8 = 63-lzcount(bound);
 local lowbits:8 = (1 << (k+1))-1;
 local count:8 = (zext(raw:2) & lowbits) / (b*2);
 local inv:1 = (raw:2 & 0x8000)!=0;
''',low_mask('all',128,'bound'),low_mask('prefix',128,'count*b'),
    const_repeat('s2',128,0x5555555555555555),const_repeat('s4',128,0x1111111111111111),const_repeat('s8',128,0x0101010101010101),
    '''local type1:128 = zext(b==1); type1 = 0-type1;
 local type2:128 = zext(b==2);
 local type4:128 = zext(b==4);
 local type8:128 = zext(b==8);
 local typemask:128 = type1 | s2*type2 | s4*type4 | s8*type8;
 local invert:128 = zext(inv); invert=0-invert;
 local valid:128 = zext(tag!=0); valid=0-valid;
 out = (prefix ^ (all & invert)) & all & typemask & valid;
}'''];macro('\n'.join(lines))

def while_ctor(c):
    name=c['instruction'];mn=name.split('_')[0].lower();pair='_PP_' in name;pn='_PN_' in name;wr=mn in ('whilewr','whilerw');suffix=mn[5:];desc=suffix in ('gt','ge','hi','hs');eq=suffix in ('ge','le','ls','hs');sgn=suffix in ('gt','ge','lt','le')
    for size in range(4):
      b=1<<size;letter='bhsd'[size]
      for sf in ((0,1) if not(pair or pn or wr) else (1,)):
        extra=[(22,2,size)]+([(12,1,sf)] if not(pair or pn or wr) else [])
        rn='Rn_GPR64' if sf else 'Rn_GPR32';rm='Rm_GPR64' if sf else 'Rm_GPR32'
        using=[rn,rm];nvec='1';pd=f(0,4)
        if pair:pd=f(1,3);using += [pd];dest=f'CP1PP{letter}';using += [dest];index=f'({pd}*2)';nvec='2'
        elif pn:pd=f(0,3);using+=[pd,f(13,1)];dest=f'CP1PNd{letter}';using+=[dest];index=f'({pd}+8)';nvec=f'(2 << {f(13,1)})'
        else:using +=[pd];dest=f'"p"^{pd}^".{letter}"';index=pd
        body=['local cur:8; cp1_current_bytes(cur);',f'local total:8 = (cur >> {size}) * {nvec};','local count:8;']
        if wr:
            body += [f'local x:16=zext({rn}); local y:16=zext({rm});','local delta:16=y-x;']
            if mn=='whilerw':body += ['local neg:16=zext(delta s< 0); neg=0-neg; delta=(delta^neg)-neg;']
            body += [f'local distance:16=delta s>> {size};','local useall:1 = (distance s<= 0) || (zext(total) < distance);','count = total*zext(useall) + distance:8*zext(!useall);']
        else:
            extend='sext' if sgn else 'zext';cmp=('s' if sgn else '')+('<=' if eq else '<');test=f'y {cmp} x' if desc else f'x {cmp} y'
            body += [f'local x:16={extend}({rn}); local y:16={extend}({rm});',f'local valid:1 = {test};',f'local distance:16 = {"x-y" if desc else "y-x"} + {int(eq)};']
            # Equality against the limiting value remains true after wrap.
            nbits=64 if sf else 32
            body += [f'local limit:16=1; limit=limit << {nbits-1 if sgn else nbits};']
            extreme='y == (0-limit)' if (desc and sgn) else ('y==0' if desc else ('y == limit-1'))
            body += [(f'local unlimited:1 = ({extreme});' if eq else 'local unlimited:1 = 0;'),'local saturated:1 = unlimited || (zext(total) < distance);','count = (total*zext(saturated) + distance:8*zext(!saturated))*zext(valid);']
        body += [('NG = (count!=0) && (count==total);' if desc else 'NG = count!=0;'),'ZR = count==0;',f'CY = count=={0 if desc else "total"};' if desc else 'CY = count!=total;','OV = 0;']
        if pn:
            partial=f'0x8000 + {b} + {2*b}*(total-count)' if desc else f'{b}+{2*b}*count'
            body += [f'local enc:8 = ({partial})*zext(count!=total) + {0x8000+b}*zext(count==total);','enc = enc*zext(count!=0);','local result:32=zext(enc);',pwrite('result',f'{index}:4')]
        else:
            nbytes=64 if pair else 32
            body += [low_mask('result',nbytes,f'count*{b}')]
            if desc:body += [f'result = result << ((total-count)*{b});']
            body += [stride('spacing',nbytes,b,'total*'+str(b)),'result = result & spacing;',low_mask('active',32,'cur')]
            if pair:
                body += ['local lower:32=result:32 & active;','local shifted:64=result >> cur; local upper:32=shifted:32 & active;',pwrite('lower',f'{index}:4'),pwrite('upper',f'({index}+1):4')]
            else:body += ['result = result & active;',pwrite('result',f'{index}:4')]
        display=f'{mn} {dest}, {rn}, {rm}'
        if pn:display+=', CP1VL13';using+=['CP1VL13']
        ctor(c,display,'\n'.join(body),extra,using)

def predicate_ctor(c):
    name=c['instruction'];mn=name.split('_')[0].lower();pd=f(0,4)
    if name=='PFALSE_P__':
        ctor(c,f'pfalse "p"^{pd}^".b"',f'local result:32=0; cp1_write_p(result,{pd}:4);',using=[pd]);return
    if name=='PSEL_P_PPi__':
        pn=f(10,4);pm=f(5,4);rv=f(16,2);tlo=f(18,3);thi=f(22,1);i1=f(23,1)
        for t in range(1,16):
            b=t&-t;size=b.bit_length()-1
            body=f'''local cur:8; cp1_current_bytes(cur);
local source:32; local selector:32; cp1_read_p(source,{pn}:4); cp1_read_p(selector,{pm}:4);
local w:4; cp1_read_w(w,({rv}+12):4);
local offset:8 = ({i1}*16+{t})/{b*2};
local ix:8 = (zext(w)+offset) % (cur/{b});
local shifted:32 = selector >> (ix*{b});
local bit:32 = shifted & 1; local keep:32=0-bit;
local result:32=source & keep;
cp1_write_p(result,{pd}:4);'''
            ctor(c,f'psel "p"^{pd}, "p"^{pn}, "p"^{pm}^".{"bhsd"[size]}["^CP1Wv16, CP1PSelImm{t}^"]"',body,[(18,3,t&7),(22,1,t>>3)],using=[pd,pn,pm,rv,i1,'CP1Wv16',f'CP1PSelImm{t}'])
        return
    for size in range(4):
        b=1<<size;letter='bhsd'[size];body=['local cur:8; cp1_current_bytes(cur);'];using=[pd];extra=[(22,2,size)]
        if name in ('PTRUE_P_S__','PTRUES_P_S__'):
            pat=f(5,5);using+=[pat];display=f'{mn} "p"^{pd}^".{letter}", CP1Pattern';using+=['CP1Pattern']
            body += [f'local total:8 = cur >> {size};',f'local pat:8={pat};','local fixed:8 = pat*zext((pat>=1)&&(pat<=8));','fixed = fixed + (1 << (pat-5))*zext((pat>=9)&&(pat<=13));','local highest:8=1 << (63-lzcount(total));','local count:8 = fixed*zext(fixed<=total);','count = count + highest*zext(pat==0) + ((total>>2)<<2)*zext(pat==29) + ((total/3)*3)*zext(pat==30) + total*zext(pat==31);',low_mask('result',32,f'count*{b}'),stride('spacing',32,b,'cur'),'result = result & spacing;',pwrite('result',f'{pd}:4')]
            if name.startswith('PTRUES'):body += ['NG=count!=0; ZR=count==0; CY=count==0; OV=0;']
        elif name=='PTRUE_PN_I__':
            pnd=f(0,3);using=[pnd];display=f'ptrue CP1PNd{letter}';using += [f'CP1PNd{letter}'];body += [f'local result:32={0x8000+b};',pwrite('result',f'({pnd}+8):4')]
        else:
            cn=name=='CNTP_R_PN__';pair=name=='PEXT_PP_RR__';src=f(5,4 if cn else 3);srcidx=src if cn else f'({src}+8)';using+=[src]
            body+=['local raw:32; '+f'cp1_read_p(raw,{srcidx}:4);','local expanded:128; cp1_counter_expand(expanded,raw,cur);']
            if cn:
                vl=f(10,1);using+=['Rd_GPR64',vl,'CP1PNn5','CP1VL10'];display=f'cntp Rd_GPR64, CP1PNn5^".{letter}", CP1VL10'
                body += [stride('spacing',128,b,'cur*4'),low_mask('active',128,f'cur*(2 << {vl})'),'local selected:128 = expanded & spacing & active;','Rd_GPR64 = popcount(selected);']
            else:
                part=f(8,1 if pair else 2);using+=[part,'CP1PN8n5'];display=f'pext '+(f'CP1PEPair{letter}' if pair else f'"p"^{pd}^".{letter}"')+', CP1PN8n5^["'+''
                display=f'pext '+(f'CP1PEPair{letter}' if pair else f'"p"^{pd}^".{letter}"')+f', CP1PN8n5^"["^{part}^"]"'
                if pair:using +=[f'CP1PEPair{letter}']
                body += [stride('spacing',32,b,'cur'),low_mask('active',32,'cur'),f'local shifted:128 = expanded >> ({part}*cur*{2 if pair else 1});','local first:32 = shifted:32 & spacing & active;']
                if pair:body += ['shifted = shifted >> cur; local second:32=shifted:32 & spacing & active;']
                body += [pwrite('first',f'{pd}:4')]
                if pair:body += [pwrite('second',f'(({pd}+1)%16):4')]
        ctor(c,display,'\n'.join(body),extra,using)

def control_ctor(c):
    name=c['instruction']
    if name.startswith(('SMSTART','SMSTOP')):
        enable=int(name.startswith('SMSTART'));sm=int(not name.endswith('_ZA'));za=int(not name.endswith('_SM'))
        suffix=' sm' if name.endswith('_SM') else ' za' if name.endswith('_ZA') else ''
        ctor(c,('smstart' if enable else 'smstop')+' "'+suffix.strip()+'"',f'cp1_transition({sm}:8,{za}:8,{enable}:8);');return
    if name.startswith('RDSVL'):
        imm=f(5,6);ctor(c,'rdsvl Rd_GPR64, "#"^sme_imm6',f'local immediate:8={imm};\nRd_GPR64 = sme_svl_bytes*(immediate & 31) - (sme_svl_bytes*32)*(immediate >> 5);',using=['Rd_GPR64','sme_imm6',imm]);return
    if name=='ZERO_ZT_I__':ctor(c,'zero "{zt0}"','zt0=0;');return
    if name=='ZERO_ZA_I__':
        mask=f(0,8);lines=[f'local selection:8={mask};']
        for t in range(8):lines += [f'local keep{t}:256=zext(((selection >> {t}) & 1)==0); keep{t}=0-keep{t};']
        for r in range(256):lines += [f'cp1_za_r{r}=cp1_za_r{r} & keep{r%8};']
        ctor(c,'zero SMEZeroMask','\n'.join(lines),using=['SMEZeroMask',mask]);return
    n,g=map(int,re.fullmatch(r'ZERO_ZA([124])_RI_([124])',name).groups());rv=f(13,2)
    offbits=3 if n==1 or (n==2 and g==1) else 2 if n==2 or (n==4 and g==1) else 1
    off=f(0,offbits)
    lines=[f'local w:4; cp1_read_w(w,({rv}+8):4);',f'local stride:8=sme_svl_bytes/{g};',f'local row:8=(zext(w)+{off}*{n})%stride;',f'row=(row >> {int(math.log2(n))}) << {int(math.log2(n))};']
    for group in range(g):
        for j in range(n):lines += [f'local ptr{group}_{j}:4=0x20000+((row+{j}+stride*{group}):4)*256;',f'*[register]:256 ptr{group}_{j}=0;']
    ctor(c,f'zero "{{za.d["^CP1Wv13_8, "#"^{off}, "vgx{g}]}}"','\n'.join(lines),using=[rv,off,'CP1Wv13_8'])

def bit_pattern(var,nbytes,lowwidth,period):
    lines=[low_mask(var,nbytes,str(lowwidth))];shift=period
    while shift<nbytes*8:
        lines.append(f'{var}=({var} << {shift}) | {var};');shift*=2
    return '\n'.join(lines)

def build_movement_macros():
    # Predicate bit i controls byte i. Dilation maps it to bit 8*i; multiplication
    # by a lane mask fills only that element. All stages are ordinary p-code.
    for b in (1,2,4,8,16):
        lines=[f'macro cp1_predicate_bytes_{b}(out,raw,current) {{',low_mask('active',32,'current'),stride('spacing',32,b,'current'),
               'local predicate:32=raw & active & spacing;','local expanded:256=zext(predicate);']
        h=128
        while h:
            lines += [bit_pattern(f'mask{h}',256,h,8*h),f'expanded=(expanded | (expanded << {7*h})) & mask{h};'];h//=2
        lines += [low_mask('lane',256,str(8*b)),'out=expanded*lane;','}'];macro('\n'.join(lines))
        # ZA physical columns increase with addresses; whole-register integer
        # significance is reversed on BE. Reverse element order, never byte order
        # within an element. This permutation is its own inverse.
        lines=[f'macro cp1_row_order_{b}(out,input) {{','out=input;','@if DATA_ENDIAN == "big"'];h=b
        while h<256:
            lines += [bit_pattern(f'order{h}',256,h*8,h*16),f'out=((out & order{h}) << {h*8}) | ((out >> {h*8}) & order{h});'];h*=2
        lines += ['@endif','}'];macro('\n'.join(lines))
    for b in (1,2,4):
        maximum=256//b;lines=[f'macro cp1_expand_indices_{b}(out,input) {{',low_mask('inputmask',256,str(maximum*2)),'out=input & inputmask;'];h=maximum//2
        while h:
            lines += [bit_pattern(f'indexmask{h}',256,h*2,h*b*8),f'out=(out | (out << {h*(b*8-2)})) & indexmask{h};'];h//=2
        lines += ['}'];macro('\n'.join(lines))

def raw_fields(c):
    return {x['name']:f(x['lsb'],x['width']) for x in c['encoding']['fields'] if x['kind']!='fixed'}

def zgroup_table(name,field,nreg,letter,base_expr=None,stride_value=1):
    begin=base_expr or f'{field}*{nreg}'
    display=(f'"z"^first^".{letter}"' if nreg==1 else
             '"{'+', '.join(f'z"^{"first" if j==0 else "last"+str(j)}^".{letter}' for j in range(nreg))+'}"')
    actions=f'first={begin};'+''.join(f'last{j}=first+{j*stride_value};' for j in range(1,nreg))
    emit(f'{name}: {display} is {field} [{actions}] {{export *[const]:4 first;}}')
    return name

def packed_mova_tables():
    # Pure operand exports, no new storage or emitted p-code. The split Z/P
    # layout remains the existing ABI; byte order is handled in the body.
    for n in range(32):
        emit(f'CP1MovaZLow: is {f(5,5)}={n} {{export z{n};}}')
        emit(f'CP1MovaZHigh: is {f(5,5)}={n} {{export cp1_zh{n};}}')
        emit(f'CP1MovaLowAddress: is {f(5,5)}={n} {{export {0x5000+n*32}:128;}}')
        emit(f'CP1MovaHighAddress: is {f(5,5)}={n} {{export {0x10000+n*224}:128;}}')
    for n in range(8):
        emit(f'CP1MovaPLow: is {f(10,3)}={n} {{export p{n};}}')
        emit(f'CP1MovaPHigh: is {f(10,3)}={n} {{export cp1_ph{n};}}')
    for n in range(4):emit(f'CP1MovaW: is {f(13,2)}={n} {{export w{12+n};}}')

def packed_mova_body(b,off,tile):
    """Select ZA or the same source Z cell as each branch-free STORE target.

    The inactive path is an ordinary register-space self-store: it preserves
    source bytes, including tails and aliases, but introduces a possible Z
    write dependency for native SSA. Snapshot both source pieces before stores.
    No RAM access, new architectural storage, or opaque p-code is introduced.

    For B=2**32, lanes=(B**32-1)/(B-1), and ramp has digits31..0.
    G=(2**1056-1)/(2**33-1). For a32-bit predicate x, product x*G
    has distinct terms2**(i+33*j), with no carries. Shifting31 and
    masking by lanes selects i+j=31, reversing the32 predicate bits.
    Multiplying these bits by B-1 yields independent32-bit pointer masks.
    Width132 bytes retains the complete product; all pointers fit18 bits.
    Each batch consumes32 predicate bits and32 bytes of Z. H/S use only
    their b-spaced predicate/element slots; unused bits cannot affect them.
    """
    body=[f'local selected:8=zext(CP1MovaW);',f'selected=(selected+{off}) % (sme_svl_bytes/{b});',f'local base:4=0x20000+{tile}*256+selected:4*{b};',
          'local source_low:32=CP1MovaZLow;','local source_high:224=CP1MovaZHigh;',
          'local allones:132=0-1;','local pg:32=zext(CP1MovaPHigh);','pg=(pg << 32) | zext(CP1MovaPLow);','local active:32=allones:32 >> (256-sme_svl_bytes);','pg=pg & active;',
          'local lanes:128=allones:128/0xffffffff;','local ramp:128=allones:128/0xfffffffe00000001;',
          'local multiplier:132=allones/0x1ffffffff;',
          'local targets:128=zext(base);','targets=targets*lanes+ramp*256;','local targetstep:128=lanes*8192;',
          'local sourcestep:128=lanes*32;',
          '@if DATA_ENDIAN == "big"',f'local sources:128=(CP1MovaLowAddress+{32-b})*lanes-ramp;',
          '@else','local sources:128=CP1MovaLowAddress*lanes+ramp;','@endif']
    if b == 1:
        # Byte tiles have no tile selector or size scaling.
        body[1]=f'selected=(selected+{off}) % sme_svl_bytes;'
        body[2]='local base:4=0x20000+selected:4;'
    for g in range(8):
        if g==1:
            body += ['@if DATA_ENDIAN == "big"',f'sources=(CP1MovaHighAddress+{224-b})*lanes-ramp;','@else','sources=CP1MovaHighAddress*lanes+ramp;','@endif']
        elif g>1:
            body += ['@if DATA_ENDIAN == "big"','sources=sources-sourcestep;','@else','sources=sources+sourcestep;','@endif']
        if g:body += ['targets=targets+targetstep;']
        body += [f'local spread{g}:132=zext(pg[{g*32},32]);',f'spread{g}=spread{g}*multiplier;',f'spread{g}=spread{g} >> 31;',f'local flags{g}:128=spread{g}:128 & lanes;',f'flags{g}=flags{g}*0xffffffff;',f'local pointers{g}:128=((targets ^ sources) & flags{g}) ^ sources;']
        for e in range(0,32,b):
            source='source_low' if g==0 else 'source_high'
            sh=e if g==0 else (g-1)*32+e
            body += [f'*[register]:{b} pointers{g}[{(31-e)*32},32]={source}[{sh*8},{b*8}];']
    return body

def movement_ctor(c):
    name=c['instruction'];d=raw_fields(c);array='Rv' in d;pred='Pg' in d;zero=name.startswith('MOVAZ');toza='Zn' in d
    group=re.search(r'(?:MZ|ZA)([24])',name);nreg=int(group[1]) if group else 1
    sizeletter='B' if array else re.search(r'_([BHWSDQ])1?$',name)[1];b={'B':1,'H':2,'W':4,'S':4,'D':8,'Q':16}[sizeletter];letter={1:'b',2:'h',4:'s',8:'d',16:'q'}[b]
    off=next((value for key,value in d.items() if key.startswith('off') or key=='o1'),'0');tile=d.get('ZAd',d.get('ZAn','0'));zf=d['Zn' if toza else 'Zd'];rs=d.get('Rv',d.get('Rs'))
    ztable=zgroup_table('CP1ZG_'+name,zf,nreg,letter)
    for vertical in ((0,) if array else (0,1)):
        using=list(d.values())+[ztable];extra=[] if array else [(15,1,vertical)]
        body=['local cur:8=sme_svl_bytes;',f'local windex:4={rs}+{8 if array else 12};','local w:4; cp1_read_w(w,windex);',f'local znindex:4={zf}*{nreg};']
        if array:body += [f'local rowstride:8=cur/{nreg};',f'local slice:8=(zext(w)+{off})%rowstride;']
        else:
            shift=int(math.log2(nreg));body += [f'local elements:8=cur/{b};',f'local aligned:8=(zext(w) >> {shift}) << {shift};',f'local slice:8=(aligned+{off}*{nreg})%elements;',f'local tile:8={tile};']
        vertical_predicate=vertical and toza and pred and nreg == 1
        compact_predicate=vertical_predicate and b >= 8
        if pred:
            body += [f'local pg:32; cp1_read_p(pg,{d["Pg"]}:4);']
            if vertical_predicate:
                # cur is an architectural multiple of 16 bytes, hence of b.
                # ((1<<cur)-1)/((1<<b)-1) has one bit every b positions.
                body += [low_mask('predicate_active',32,'cur')]
                if b == 1:body += ['local selected_predicate:32=pg & predicate_active;']
                else:body += [f'local selected_predicate:32=pg & (predicate_active/{(1<<b)-1});']
                if not compact_predicate:
                    body += ['local expanded_predicate:256=zext(selected_predicate);']
                    h=128
                    # Input has no bits below the b-bit lane granularity;
                    # dilation stages h<b would leave it unchanged.
                    while h >= b:
                        body += [bit_pattern(f'predicate_mask{h}',256,h,8*h),
                                 f'expanded_predicate=(expanded_predicate | (expanded_predicate << {7*h})) & predicate_mask{h};']
                        h//=2
                    body += [f'local activebytes:256=expanded_predicate*{(1<<(8*b))-1};']
            else:body += [f'local activebytes:256; cp1_predicate_bytes_{b}(activebytes,pg,cur);']
        else:body += [low_mask('activebytes',256,'cur*8')]
        for j in range(nreg):
            body += [f'local vector{j}:256; cp1_read_z(vector{j},znindex+{j});']
        if not vertical:
            for j in range(nreg):
                row=f'slice+rowstride*{j}' if array else f'tile+(slice+{j})*{b}'
                body += [f'local row{j}:8={row};',f'local address{j}:4=0x20000+row{j}:4*256;',f'local storage{j}:256=*[register]:256 address{j};',f'local content{j}:256; cp1_row_order_{b}(content{j},storage{j});']
                if toza:
                    body += [f'content{j}=content{j} ^ ((content{j} ^ vector{j}) & activebytes);',f'cp1_row_order_{b}(storage{j},content{j});',f'*[register]:256 address{j}=storage{j};']
                else:
                    body += [f'vector{j}=vector{j} ^ ((vector{j} ^ content{j}) & activebytes);',f'cp1_write_z(vector{j},znindex+{j});']
                    if zero:body += [f'content{j}=content{j} ^ (content{j} & activebytes);',f'cp1_row_order_{b}(storage{j},content{j});',f'*[register]:256 address{j}=storage{j};']
        elif toza and pred and nreg == 1:
            # The expanded predicate already contains an all-zero/all-one mask
            # for every element. Fixed subpieces alias those bytes directly;
            # rebuilding each mask from a shifted byte wastes ordinary p-code.
            # Preserve the bounded 256-byte ABI and merge inactive/tail cells.
            body += [f'local baseaddress:4=0x20000+tile:4*256+slice:4*{b};']
            for e in range(256//b):
                source=f'vector0({e*b})' if e else f'vector0:{b}'
                mask=f'activebytes({e*b})' if e else f'activebytes:{b}'
                body += [f'local address{e}:4=baseaddress+{e*b*256};',
                         f'local chunk{e}:{b}=*[register]:{b} address{e};',
                         f'local source{e}:{b}={source};']
                if compact_predicate:
                    flag=f'selected_predicate({e*b//8})' if e else 'selected_predicate:1'
                    body += [f'local flag{e}:1={flag};',f'local mask{e}:{b}=zext(flag{e});',f'mask{e}=0-mask{e};']
                else:body += [f'local mask{e}:{b}={mask};']
                body += [f'chunk{e}=chunk{e} ^ ((chunk{e} ^ source{e}) & mask{e});',
                         f'*[register]:{b} address{e}=chunk{e};']
        else:
            # Gather/scatter the whole adjacent-column group with one register
            # LOAD per physical row. Merge the gathered Z vectors once, not once
            # per lane. This is still straight-line bounded register dataflow.
            chunkbytes=b*nreg
            body += [f'local baseaddress:4=0x20000+tile:4*256+slice:4*{b};']
            if not toza:
                for j in range(nreg):body += [f'local gathered{j}:256=0;']
            for e in range(256//b):
                sh=e*b*8
                body += [f'local address{e}:4=baseaddress+{e*b*256};',f'local chunk{e}:{chunkbytes}=*[register]:{chunkbytes} address{e};']
                if toza:body += [f'local replacement{e}:{chunkbytes}=0;']
                for j in range(nreg):
                    body += ['@if DATA_ENDIAN == "big"',f'local shift{e}_{j}:4={(nreg-1-j)*b*8};','@else',f'local shift{e}_{j}:4={j*b*8};','@endif']
                    if toza:
                        body += [f'local source{e}_{j}:256=vector{j} >> {sh};',f'local cell{e}_{j}:{b}=source{e}_{j}:{b};',f'local wide{e}_{j}:{chunkbytes}=zext(cell{e}_{j});',f'replacement{e}=replacement{e} | (wide{e}_{j} << shift{e}_{j});']
                    else:
                        body += [f'local source{e}_{j}:{chunkbytes}=chunk{e} >> shift{e}_{j};',f'local cell{e}_{j}:{b}=source{e}_{j}:{b};',f'local wide{e}_{j}:256=zext(cell{e}_{j});',f'gathered{j}=gathered{j} | (wide{e}_{j} << {sh});']
                if toza:
                    # Only the nreg=1 form is predicated; group forms use all
                    # active lanes. Replicate the byte predicate over the chunk.
                    body += [f'local shiftedmask{e}:256=activebytes >> {sh};',f'local byteflag{e}:1=shiftedmask{e}:1;',f'local enabled{e}:1=byteflag{e}!=0;',f'local mask{e}:{chunkbytes}=zext(enabled{e}); mask{e}=0-mask{e};',f'chunk{e}=chunk{e} ^ ((chunk{e} ^ replacement{e}) & mask{e});',f'*[register]:{chunkbytes} address{e}=chunk{e};']
                elif zero:
                    body += [f'local preserve{e}:1={e*b}>=cur;',f'local keep{e}:{chunkbytes}=zext(preserve{e});',f'*[register]:{chunkbytes} address{e}=chunk{e}*keep{e};']
            if not toza:
                for j in range(nreg):
                    body += [f'vector{j}=vector{j} ^ ((vector{j} ^ gathered{j}) & activebytes);',f'cp1_write_z(vector{j},znindex+{j});']
        if vertical_predicate and b <= 4:
            body=packed_mova_body(b,off,tile)
            using += ['CP1MovaZLow','CP1MovaZHigh','CP1MovaLowAddress','CP1MovaHighAddress','CP1MovaPLow','CP1MovaPHigh','CP1MovaW']
        # Reuse the upstream MOV alias for already-present predicated MOVA forms.
        mnemonic='movaz' if zero else 'mov' if pred else 'mova'
        table='CP1ZA_'+name+str(vertical);rstable='CP1Wv13_8' if array else 'CP1Ws13'
        if array:display=f'"za.d["^{rstable}, "#"^offset^", vgx{nreg}]"'
        else:display=f'"za"^t^"{"v" if vertical else "h"}.{letter}["^{rstable}, "#"^offset^"'+(f':"^lastoffset^"' if nreg>1 else '')+']"'
        action=('' if array else f't={tile}+0; ')+f'offset={off}*{1 if array else nreg};'+(f'lastoffset=offset+{nreg-1};' if nreg>1 and not array else '')
        emit(f'{table}: {display} is '+' & '.join(list(d.values())+[rstable])+f' [{action}] {{export *[const]:4 {"offset" if array else "t"};}}')
        using += [table]
        operands=[table,ztable] if toza else [ztable,table]
        if pred:operands.insert(1,f'"p"^{d["Pg"]}^"/m"')
        ctor(c,mnemonic+' '+', '.join(operands),'\n'.join(body),extra,using)

def luti_ctor(c):
    name=c['instruction'];d=raw_fields(c);nreg=2 if 'MZ2' in name else 4 if 'MZ4' in name else 1;strided='D' in d
    zfield=d['Zd'];zn=d['Zn'];imm=next(value for key,value in d.items() if key.startswith('i'))
    for size in range(2 if strided else 3):
        b=1<<size;letter='bhs'[size];spacing=8 if nreg==2 else 4 if strided else 1
        if not strided:spacing=1
        dst=f'16*{d["D"]}+{zfield}' if strided else f'{zfield}*{nreg}'
        table=zgroup_table('CP1LZ_'+name+str(size),zfield,nreg,letter,dst,spacing)
        if strided:
            # The pretty-printer's operand table also needs the split high bit.
            old=CON[-1];CON[-1]=old.replace(' is '+zfield+' [',' is '+zfield+' & '+d['D']+' [')
        lines=['local cur:8=sme_svl_bytes;',f'local elements:8=cur/{b};',f'local segment:8={imm}%{b*8//(2*nreg)};',f'local first:4={dst};',f'local source:256; cp1_read_z(source,{zn}:4);','local tablebits:64=zt0;',low_mask('active',256,'cur*8'),bit_pattern('ones',256,1,b*8),low_mask('lanemask',256,str(b*8))]
        for t in range(4):
            lines += [f'local tableshift{t}:64=tablebits >> {32*t};',f'local tablevalue{t}:{b}=tableshift{t}:{b};',f'local broadcast{t}:256=zext(tablevalue{t})*ones;']
        for j in range(nreg):
            lines += [f'local packed{j}:256=source >> ((segment*{nreg}+{j})*elements*2);',f'local indices{j}:256; cp1_expand_indices_{b}(indices{j},packed{j});',f'local lower{j}:256=indices{j} & ones;',f'local upper{j}:256=(indices{j} >> 1) & ones;',f'local select0_{j}:256=(lower{j} ^ ones) & (upper{j} ^ ones);',f'local select1_{j}:256=lower{j} & (upper{j} ^ ones);',f'local select2_{j}:256=(lower{j} ^ ones) & upper{j};',f'local select3_{j}:256=lower{j} & upper{j};',f'local result{j}:256='+ ' | '.join(f'(broadcast{t} & (select{t}_{j}*lanemask))' for t in range(4))+';',f'result{j}=result{j} & active;',f'cp1_write_z(result{j},first+{j*spacing});']
        ctor(c,f'luti2 {table}, "zt0", "z"^{zn}^"["^{imm}^"]"','\n'.join(lines),[(12,2,size)],list(d.values())+[table])

def add_ctor(c):
    name=c['instruction'];d=raw_fields(c);b=int(name.split('_')[-1])//8;horizontal=name.startswith('ADDHA');letter='s' if b==4 else 'd';tile=d['ZAda'];pn=d['Pn'];pm=d['Pm'];zn=d['Zn']
    lines=['local cur:8=sme_svl_bytes;',f'local tile:4={tile};',f'local source:256; cp1_read_z(source,{zn}:4);',f'local prows:32; cp1_read_p(prows,{pn}:4);',f'local pcols:32; cp1_read_p(pcols,{pm}:4);',f'local colmask:256; cp1_predicate_bytes_{b}(colmask,pcols,cur);',bit_pattern('ones',256,1,b*8),f'local tops:256=ones << {b*8-1};','local lows:256=tops-ones;']
    for r in range(256//b):
        lines += [f'local rowbit{r}:32=prows >> {r*b};',f'local enabled{r}:1=((rowbit{r} & 1)!=0) && ({r*b}<cur);',f'local rowmask{r}:256=zext(enabled{r}); rowmask{r}=0-rowmask{r};',f'local mask{r}:256=colmask & rowmask{r};',f'local ptr{r}:4=0x20000+(tile+{r*b})*256;',f'local storage{r}:256=*[register]:256 ptr{r};',f'local original{r}:256; cp1_row_order_{b}(original{r},storage{r});']
        addend='source'
        if not horizontal:
            lines += [f'local shifted{r}:256=source >> {r*b*8};',f'local lane{r}:{b}=shifted{r}:{b};',f'local addend{r}:256=zext(lane{r})*ones;'];addend=f'addend{r}'
        lines += [f'local sum{r}:256=((original{r} & lows)+({addend} & lows)) ^ ((original{r} ^ {addend}) & tops);',f'original{r}=original{r} ^ ((original{r} ^ sum{r}) & mask{r});',f'cp1_row_order_{b}(storage{r},original{r});',f'*[register]:256 ptr{r}=storage{r};']
    ctor(c,f'{"addha" if horizontal else "addva"} "za"^{tile}^".{letter}", "p"^{pn}^"/m", "p"^{pm}^"/m", "z"^{zn}^".{letter}"','\n'.join(lines),using=list(d.values()))

def decode_only_ctor(c):
    name=c['instruction']
    if name.startswith('PMOV'):
        # The research pins this class mask, not a tested textual-operand grammar.
        # Keep exact class identity instead of fabricating an operand renderer.
        clone={'encoding':{'base':c['base'],'mask':c['mask']}}
        emit(f'# {name}; {c["sail"]}\n:pmov "/* {name}: decode-only */"\nis {pattern(clone)}\nunimpl')
    elif 'Z8Z8' in name:
        d=raw_fields(c);letter='h' if 'ZA16' in name else 's'
        display=f'fmopa "za"^{d["ZAda"]}^".{letter}", "p"^{d["Pn"]}^"/m", "p"^{d["Pm"]}^"/m", "z"^{d["Zn"]}^".b", "z"^{d["Zm"]}^".b"'
        emit(f'# {name}; {c["sources"]["arm_xml"]}\n# Reserved FPMR input formats retain R22907 nondeterminism: no value is folded.\n:{display}\nis {pattern(c,using=list(d.values()))}\nunimpl')

def tables():
    for size,letter in enumerate('bhsd'):
        pd=f(1,3);pnd=f(0,3);p=f(0,4)
        emit(f'CP1PP{letter}: "{{p"^d^".{letter}, p"^e^".{letter}}}" is {pd} [d={pd}*2; e=d+1;] {{export *[const]:4 d;}}')
        emit(f'CP1PNd{letter}: "pn"^d^".{letter}" is {pnd} [d={pnd}+8;] {{export *[const]:4 d;}}')
        emit(f'CP1PEPair{letter}: "{{p"^{p}^".{letter}, p"^e^".{letter}}}" is {p} [e=({p}+1) & 15;] {{export *[const]:4 {p};}}')
    for bit in (10,13):emit(f'CP1VL{bit}: "vlx"^n is {f(bit,1)} [n=2 << {f(bit,1)};] {{export *[const]:8 n;}}')
    emit(f'CP1PNn5: "pn"^{f(5,4)} is {f(5,4)} {{export *[const]:4 {f(5,4)};}}')
    emit(f'CP1PN8n5: "pn"^n is {f(5,3)} [n={f(5,3)}+8;] {{export *[const]:4 n;}}')
    emit(f'CP1Ws13: \"w\"^n is {f(13,2)} [n={f(13,2)}+12;] {{export *[const]:4 n;}}')
    for bit,base in ((16,12),(13,8)):
        nm=f'CP1Wv{bit}'+('_8' if base==8 else '')
        emit(f'{nm}: "w"^n is {f(bit,2)} [n={f(bit,2)}+{base};] {{export *[const]:4 n;}}')
    for t in range(1,16):
        b=t&-t;emit(f'CP1PSelImm{t}: "#"^imm is {f(23,1)} [imm=({f(23,1)}*16+{t})/{2*b};] {{export *[const]:8 imm;}}')
    patterns={0:'pow2',**{n:f'vl{n}' for n in range(1,9)},**{n:f'vl{1<<(n-5)}' for n in range(9,14)},29:'mul4',30:'mul3',31:'all'}
    for p in range(32):emit(f'CP1Pattern: "{patterns.get(p,"#"+str(p))}" is {f(5,5)}={p} {{export {p}:8;}}')

def decimal_displays(constructors):
    """Literal operand-name subtables: no p-code and no changes to numeric fields.

    The bundled C++ ValueSymbol/OperandSymbol printers always use hexadecimal,
    even for dec token fields. Keep the original fields/actions for semantics,
    and add display-only tables whose text is an assembler register number.
    """
    import itertools
    tables={}; definitions=[]; output=[]
    for source in constructors:
        match=re.search(r'(^[^#\n]*:.*?)(\s+is\s+)([^\[{\n]+)(\[[^\]]*\])?',source,re.M|re.S)
        if not match:
            output.append(source);continue
        display,sep,pattern,actions=match.groups();actions=actions or ''
        exprs={}
        for name,expr in re.findall(r'(\w+)\s*=\s*([^;]+);',actions):
            exprs[name]=re.sub(r'\b\w+\b',lambda m:'('+exprs[m[0]]+')' if m[0] in exprs else m[0],expr)
        used=[]; replaced={}
        def replace(m):
            quoted,name=m.groups()
            if not re.search(r'(?:^|[^a-zA-Z])(?:z|p|pn|w|x|za)$',quoted[1:-1]):return m[0]
            expr=exprs.get(name,name)
            fields=sorted(set(re.findall(r'cp1_f\d+_\d+',expr)))
            if re.sub(r'cp1_f\d+_\d+|[\d\s()+*<>&|/-]','',expr):
                raise ValueError('Unexpected register expression '+expr)
            if expr not in tables:
                table='CP1Decimal'+str(len(tables));tables[expr]=table
                ranges=[range(1<<int(field.rsplit('_',1)[1])) for field in fields]
                for values in itertools.product(*ranges):
                    env=dict(zip(fields,values));number=eval(expr,{'__builtins__':{}},env)
                    tests=' & '.join(f'{field}={value}' for field,value in env.items()) or 'epsilon'
                    definitions.append(f'{table}: "{number}" is {tests} {{export {number}:4;}}\n')
            table=tables[expr];used.append(table);replaced[name]=table
            return quoted+'^'+table
        display=re.sub(r'("[^"]*")\^(\w+)',replace,display)
        if used:
            if actions:
                kept=[]
                for name,expr in re.findall(r'(\w+)\s*=\s*([^;]+);',actions):
                    if name not in replaced:
                        expr=re.sub(r'\b\w+\b',lambda m:'('+exprs[m[0]]+')' if m[0] in replaced else m[0],expr)
                        kept.append(name+'='+expr+';')
                actions='['+''.join(kept)+']' if kept else ''
            tail=source[match.end():]
            for name,table in replaced.items():
                if name in exprs:
                    tail=re.sub(r'export \*\[const\]:4 '+name+r';', 'export '+table+';',tail)
            source=source[:match.end()]+tail
            pattern=pattern.rstrip()+' & '+' & '.join(dict.fromkeys(used))+' '
            source=source[:match.start()]+display+sep+pattern+actions+source[match.end():]
        output.append(source)
    return definitions+['\n'.join(line.rstrip() for line in block.splitlines())+'\n' for block in output]

def normalize_source(text):
    lines=[]; serial=0
    for line in text.splitlines():
        prefix=[]
        while True:
            m=re.search(r'\):(\d+)',line)
            if not m:break
            end=m.start();depth=1;start=end-1
            while start>=0:
                depth += (line[start]==')')-(line[start]=='(')
                if depth==0:break
                start-=1
            if start<0:raise ValueError('unbalanced cast expression')
            serial+=1;temp=f'cp1expr{serial}'
            prefix.append(f'local {temp}:8 = {line[start+1:end]};')
            line=line[:start]+temp+':'+m.group(1)+line[m.end():]
        lines.extend(prefix);lines.append(line)
    text='\n'.join(lines)+'\n'
    # Local names must not collide with globally declared architectural registers.
    names=set(re.findall(r'\blocal\s+(\w+)\s*:',text))
    for args in re.findall(r'\bmacro\s+\w+\(([^)]*)\)',text):
        names.update(x.strip() for x in args.split(','))
    # Quoted assembly literals are not semantic identifiers (notably \"w\").
    text=''.join(part if i%2 else re.sub(r'\b\w+\b',lambda m: 'cp1tmp_'+m[0] if m[0] in names else m[0],part) for i,part in enumerate(re.split(r'(\"[^\"]*\")',text)))
    return text

def main():
    p=argparse.ArgumentParser();p.add_argument('--fixture',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--manifest',type=pathlib.Path);a=p.parse_args();document=json.loads(a.fixture.read_text());catalogue=document['catalogue']
    build_core();build_movement_macros();tables();packed_mova_tables()
    for c in catalogue:
        name=c['instruction']
        if name.startswith('WHILE'):while_ctor(c)
        elif name.startswith(('PTRUE','PTRUES','PFALSE','PSEL','PEXT','CNTP')):predicate_ctor(c)
        elif name.startswith(('SMSTART','SMSTOP','RDSVL','ZERO')):control_ctor(c)
        elif name.startswith('MOVA'):movement_ctor(c)
        elif name.startswith('LUTI2'):luti_ctor(c)
        elif name.startswith(('ADDHA','ADDVA')):add_ctor(c)
        else:continue
        IMPLEMENTED.append(name)
    for c in document['decode_only']:
        if c['instruction'].startswith('PMOV'):decode_only_ctor(c)
    for c in catalogue:
        if 'Z8Z8' in c['instruction']:decode_only_ctor(c)
    header='# Generated by generate_cp1.py from the pinned encoding catalogue; no fixture expected values.\n'
    token='# CP1 TOKEN FIELDS BEGIN\n'+''.join(f' {f(lo,w)}=({lo},{lo+w-1}) dec\n' for lo,w in sorted(FIELDS))+'# CP1 TOKEN FIELDS END\n'
    instructions=a.output/'AARCH64instructions.sinc'; source=instructions.read_text()
    marker=r'# CP1 TOKEN FIELDS BEGIN\n.*?# CP1 TOKEN FIELDS END\n'
    if '# CP1 TOKEN FIELDS BEGIN' in source:
        source,count=re.subn(marker,lambda _:token,source,flags=re.S)
        if count!=1:raise ValueError('expected exactly one complete CP1 token block')
    else:
        begin=source.index('define token instrAARCH64');end=source.index('\n;',begin)
        source=source[:end]+'\n'+token+source[end:]
    instructions.write_text(source)
    (a.output/'AARCH64sme_core.sinc').write_text(header+'\n'+normalize_source('\n'.join(CORE)))
    (a.output/'AARCH64sme_cp1.sinc').write_text(header+'\n'+normalize_source('\n'.join(decimal_displays(CON))))
    if a.manifest:a.manifest.write_text(json.dumps({'scope':'candidate normal-path semantics; execution receipts determine verified coverage','forms':IMPLEMENTED},indent=2)+'\n')
    print('generated',len(IMPLEMENTED),'candidate forms;',len(FIELDS),'token fields')
if __name__=='__main__':main()
