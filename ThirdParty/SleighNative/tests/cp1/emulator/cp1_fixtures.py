#!/usr/bin/env python3
"""Schema-4 state construction and independent expected-state patch application.

No instruction effects are evaluated here. initialize() reads inputs only;
expected_state() applies explicit fixture outputs to an independent copy. A
missing/unknown directive is an error, not a silently successful comparison.
"""
from __future__ import annotations
import copy,re
from cp1_vm import SMEVM

def integer(v):
    if isinstance(v,(int,bool)):return int(v)
    return int(v,16 if v.lower().startswith(('0x','-0x')) else 10)

def source_esize(case):
    i=case['inputs'];name=case['instruction'];word=int(case['encoding'],16)
    for k in ('source_element_size','element_size','esize_bits'):
        if k in i:return integer(i[k])
    m=re.search(r'_([BHWSDQ])1?$',name)
    if m:return {'B':8,'H':16,'W':32,'S':32,'D':64,'Q':128}[m[1]]
    if name.startswith('LUTI2'):return 8<<((word>>12)&3)
    if name.startswith(('WHILE','PTRUE','PTRUES','PEXT','CNTP')):return 8<<((word>>22)&3)
    if name.startswith('PSEL'):
        t=((word>>22)&1)*8+((word>>18)&7)
        return 8*(t&-t) if t else 8
    if name.endswith('_64'):return 64
    if name.endswith('_32'):return 32
    if name.endswith('_16'):return 16
    return 8

def packed(desc,nbytes,esize):
    if not isinstance(desc,dict):return integer(desc)&((1<<(8*nbytes))-1)
    esize=integer(desc.get('element_size',desc.get('esize',esize)));count=nbytes*8//esize
    if esize not in (8,16,32,64,128):raise ValueError('unsupported fixture element width')
    value=0;mask=(1<<esize)-1
    if 'fill_byte' in desc:value=int.from_bytes(bytes([integer(desc['fill_byte'])&255])*nbytes,'little')
    if 'fill_element' in desc:value=sum((integer(desc['fill_element'])&mask)<<(esize*e) for e in range(count))
    if 'elements' in desc:
        els=desc['elements']
        if not isinstance(els,list):raise ValueError('vector elements must be a list of values')
        value=sum((integer(x)&mask)<<(esize*e) for e,x in enumerate(els))
    if 'repeat_elements' in desc:
        els=desc['repeat_elements']
        if not els:raise ValueError('empty repeat_elements')
        value=sum((integer(els[e%len(els)])&mask)<<(esize*e) for e in range(count))
    if 'two_bit_indices' in desc:value=sum((integer(x)&3)<<(2*e) for e,x in enumerate(desc['two_bit_indices']))
    for e,x in desc.get('element_overrides',{}).items():
        e=int(e);value=(value&~(mask<<(e*esize)))|((integer(x)&mask)<<(e*esize))
    allowed={'element_size','esize','fill_byte','fill_element','elements','repeat_elements','two_bit_indices','element_overrides'}
    if set(desc)-allowed:raise ValueError('unknown vector directive: '+str(set(desc)-allowed))
    return value&((1<<(8*nbytes))-1)

def svlbytes(case):return integer(case['inputs'].get('SVL_bits',case['inputs'].get('VL_bits',128)))//8

def vlbytes(case):
    i=case['inputs'];return svlbytes(case) if i.get('SM',0) else integer(i.get('nonstream_VL_bits',i.get('VL_bits',128)))//8

def fill_za(vm,b,value):
    for r in range(b):vm.write(('register',0x20000+r*256,b),int.from_bytes(bytes([integer(value)&255])*b,'little'))

def patch_slice(vm,desc,b,selective=False):
    tile,esize,sl=integer(desc['tile']),integer(desc['esize']),integer(desc['slice']);n=b*8//esize
    lanes=desc.get('elements','all') if selective else 'all'
    if lanes=='all':lanes=range(n)
    for e in lanes:
        r,c=(sl,e) if desc['orientation']=='H' else (e,sl)
        vm.write_za_cell(tile,esize,r,c,integer(desc.get('fill_element',0)))
    for e,v in desc.get('element_overrides',{}).items():
        r,c=(sl,int(e)) if desc['orientation']=='H' else (int(e),sl)
        vm.write_za_cell(tile,esize,r,c,integer(v))

def patch_tile(vm,desc,b):
    tile,esize=integer(desc['tile']),integer(desc['esize']);n=b*8//esize
    for r in range(n):
        for c in range(n):vm.write_za_cell(tile,esize,r,c,integer(desc['fill_element']))

def patch_rows(vm,rows,b):
    for row in rows:vm.write(('register',0x20000+integer(row['row'])*256,b),packed({'fill_byte':row['fill_byte']},b,8))

def initialize(case,be=False,spaces=None):
    i=case['inputs'];v=SMEVM(be=be,spaces=spaces);b=svlbytes(case);cur=vlbytes(case);esize=source_esize(case)
    if b not in range(16,257,16) or cur not in range(16,257,16):raise ValueError('invalid VL/SVL')
    v.set('SVL_BYTES',b);v.set('NONSTREAM_VL_BYTES',integer(i.get('nonstream_VL_bits',i.get('VL_bits',128)))//8)
    v.set('SVCR',(integer(i.get('ZA',0))<<1)|integer(i.get('SM',0)))
    v.set('FPMR_PRESENT',int(i.get('FPMR_present',bool('FPMR' in i or 'FPMR_fields' in i))))
    absent={x.removeprefix('FEAT_') for x in i.get('features_absent',[])}
    v.set('SME2_PRESENT',int('SME2' not in absent));v.set('ZA_VALID',1);v.set('ZT0_VALID',1)
    # Packed FPMR fields are not guessed: this checkpoint has no FP8 evaluator.
    v.fpmr_fields=dict(i.get('FPMR_fields',{}))
    if 'Z_all_fill_byte' in i:
        for n in range(32):v.set('Z'+str(n),packed({'fill_byte':i['Z_all_fill_byte']},256,8))
    if 'P_all_fill_byte' in i:
        for n in range(16):v.set('P'+str(n),packed({'fill_byte':i['P_all_fill_byte']},32,8))
    if 'FFR_fill_byte' in i:v.set('FFR',packed({'fill_byte':i['FFR_fill_byte']},32,8))
    if 'ZA_fill_byte' in i:fill_za(v,b,i['ZA_fill_byte'])
    if 'ZT0_fill_byte' in i:v.set('ZT0',packed({'fill_byte':i['ZT0_fill_byte']},64,8))
    if 'ZT0_u32_slots' in i:v.set('ZT0',packed({'elements':i['ZT0_u32_slots']},64,32))
    if 'ZA_tile' in i:patch_tile(v,i['ZA_tile'],b)
    if 'ZA_slice_initial' in i:patch_slice(v,i['ZA_slice_initial'],b)
    for s in i.get('ZA_slices_initial',[]):patch_slice(v,s,b)
    patch_rows(v,i.get('ZA_rows_initial',[]),b)
    regs=dict(i.get('registers',{}))
    for k,x in i.items():
        if re.fullmatch(r'(?:X|W|Z|PN|P)\d+',k) or k in ('SP','FPCR','FPSR','FPMR','NZCV'):regs[k]=x
        m=re.fullmatch(r'(P\d+)_active_elements',k)
        if m:
            els=range(cur*8//esize) if x=='all' else x
            v.set(m[1],sum(1<<(integer(e)*(esize//8)) for e in els))
    for k,x in regs.items():
        if k.startswith('Z'):v.set(k,packed(x,cur,esize))
        else:v.set(k,x if k=='NZCV' else integer(x))
    if 'memory' in i:
        m=i['memory'];base=integer(m['base']);size=integer(m.get('element_size',esize))//8;count=integer(m.get('count',cur//size))
        for n in range(count):v.write(('ram',base+n*size,size),integer(m.get('fill_element',0)))
        v.mapped_ranges=[(base,base+count*size)] if m.get('mapped',True) else []
        v.first_access_fault=m.get('first_access_fault')
    allowed={'SM','ZA','VL_bits','SVL_bits','nonstream_VL_bits','scalar_bits','esize_bits','element_size','source_element_size','vector_count','EL','EL2_enabled','EL3_present','EZT0','CPACR_SMEN','CPACR_FPEN','features_present','features_absent','ZA_tile','ZA_fill_byte','ZA_slice_initial','ZA_slices_initial','ZA_rows_initial','Z_all_fill_byte','P_all_fill_byte','FFR_fill_byte','ZT0_fill_byte','ZT0_u32_slots','registers','FPMR_present','FPMR_fields','EnFPM','memory','SCTLR_SA0','MaxImplementedSVL_bits'}
    for k in i:
        if k in allowed or k in regs or re.fullmatch(r'P\d+_active_elements',k):continue
        raise ValueError('unknown input directive '+k)
    return v

def expected_state(case,before):
    v=copy.deepcopy(before);x=case['expected'];b=svlbytes(case);cur=vlbytes(case);esize=source_esize(case)
    for k,y in x.get('registers',{}).items():v.set(k,packed(y,cur,esize) if k.startswith('Z') else integer(y))
    for k,y in x.items():
        if isinstance(y,str) and y in ('unchanged','ARBITRARY'):continue
        if k in ('SM','ZA','SVCR','FPCR','FPSR','FPMR','ZT0','NZCV') or re.fullmatch(r'(?:X|W|Z|PN|P)\d+',k):
            if y=='all_zero':v.set(k,0)
            elif k=='NZCV':v.set(k,y)
            elif k.startswith('Z') and k!='ZA' and k!='ZT0':v.set(k,packed(y,cur,esize))
            else:v.set(k,integer(y))
        elif k in ('Z','P','FFR') and y=='all_zero':
            if k=='FFR':v.set('FFR',0)
            else:
                for n in range(32 if k=='Z' else 16):v.set(k+str(n),0)
        elif k=='ZA_storage' and y=='all_zero':fill_za(v,b,0)
        elif k=='ZA_D_tiles_zero':
            for r in range(b):
                if r%8 in y:v.write(('register',0x20000+r*256,b),0)
        elif k=='ZA_tile_result':patch_tile(v,y,b)
        elif k=='ZA_slice_result':patch_slice(v,y,b)
        elif k=='ZA_slice_patch':patch_slice(v,y,b,True)
        elif k=='ZA_slice_patches':
            for s in y:patch_slice(v,s,b,True)
        elif k=='ZA_cell_patches':
            for c in y:v.write_za_cell(integer(c['tile']),integer(c['esize']),integer(c['row']),integer(c['col']),integer(c['value']))
        elif k=='ZA_row_patches':patch_rows(v,y,b)
        elif re.fullmatch(r'Z\d+_patch',k):
            name=k[:-6];e=integer(y['esize']);lanes=range(cur*8//e) if y['elements']=='all' else y['elements'];raw=v.get(name);mask=(1<<e)-1
            for lane in lanes:raw=(raw&~(mask<<(lane*e)))|((integer(y['fill_element'])&mask)<<(lane*e))
            v.set(name,raw)
        elif k=='memory_patch':
            es=integer(y['esize'])//8;lanes=range(cur//es) if y['elements']=='all' else y['elements']
            for lane in lanes:v.write(('ram',integer(y['base'])+lane*es,es),integer(y['fill_element']))
        elif k not in {'unchanged','all_other_storage','registers','memory_accesses','memory_writes','other_ZA_D_tiles','XZR_write','outcome','normal_destination_write','exception_entry_state','sme_exception_type','reason','state_transition_performed'}:
            raise ValueError('unhandled expected directive '+k)
    return v

def snapshot(case,vm):
    x=case['expected'];b=svlbytes(case);cur=vlbytes(case);full=any(k in x for k in ('Z','P','FFR'))
    if full:cur=256
    state={f'X{n}':f'{vm.get("X"+str(n)):016x}' for n in range(31)}
    for k in ('SP','SVCR','FPCR','FPSR','FPMR'):state[k]=f'{vm.get(k):016x}'
    state['NZCV']=vm.get('NZCV')
    for typ,count,bits in (('Z',32,cur*8),('P',16,cur),('FFR',1,cur)):
        for n in range(count):
            name=typ+str(n) if typ!='FFR' else typ
            state[name]=f'{vm.get(name)&((1<<bits)-1):0{bits//4}x}'
    if x.get('ZA_storage')!='ARBITRARY':
        state['ZA_storage']=''.join(bytes(vm.mem.get(('register',0x20000+r*256+c),0) for c in range(b)).hex() for r in range(b))
    if x.get('ZT0')!='ARBITRARY':state['ZT0']=f'{vm.get("ZT0"):0128x}'
    # Include every initialized or written memory byte, so out-of-range writes
    # cannot disappear from a comparison limited to the expected destination.
    state['memory']={str(off):val for (sp,off),val in sorted(vm.mem.items()) if sp=='ram'}
    return state

def compare_states(case,actual,expected):
    a,e=snapshot(case,actual),snapshot(case,expected)
    diff={k:{'observed':a.get(k),'expected':e.get(k)} for k in sorted(set(a)|set(e)) if a.get(k)!=e.get(k)}
    x=case['expected']
    for storage,valid in [('ZA_storage','ZA_VALID'),('ZT0','ZT0_VALID')]:
        if x.get(storage)=='ARBITRARY' and actual.get(valid)!=0:diff[valid]={'observed':actual.get(valid),'expected':0,'reason':'ARBITRARY storage must be explicitly invalidated'}
    if 'memory_accesses' in x:
        m=x['memory_accesses']
        expected_accesses=[] if m==[] else [(integer(m['base'])+n*integer(m['bytes_each']),integer(m['bytes_each'])) for n in range(integer(m['count']))]
        observed=[(v['address'],v['size']) for v in actual.memory_accesses]
        if observed!=expected_accesses:diff['memory_accesses']={'observed':observed,'expected':expected_accesses}
    return diff
