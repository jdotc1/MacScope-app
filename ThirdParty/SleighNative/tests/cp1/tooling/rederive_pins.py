#!/usr/bin/env python3
"""Re-derive existing literal SHA pins; never modifies Source/ or package/.

Default is inspect-only. --write explicitly writes the owned overlay/record/tests.
On the Mac, --recompile-with package/bin/sleigh first proves upstream byte identity,
then compiles all three owned specs in scratch. Package identity is verified before
any write. Linux checkpoint creation may explicitly allow an absent package; the
resulting null overlay pin deliberately cannot pass the full acceptance contract.
"""
from __future__ import annotations
import argparse,copy,hashlib,json,pathlib,re,shutil,stat,subprocess,tempfile
LANG=pathlib.Path('share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages')
STEMS=('AARCH64','AARCH64BE','AARCH64_AppleSilicon')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def entries(root):
    result={}
    for p in root.rglob('*'):
        mode=p.lstat().st_mode
        if stat.S_ISLNK(mode):raise ValueError(f'symlink is not permitted: {p}')
        if stat.S_ISDIR(mode):continue
        if not stat.S_ISREG(mode):raise ValueError(f'non-regular file: {p}')
        result[p.relative_to(root).as_posix()]=(p.stat().st_size,sha(p))
    return result

def tree(rows):
    digest=hashlib.sha256()
    for name,(size,member) in sorted(rows.items(),key=lambda p:p[0].encode()):
        digest.update(name.encode()+b'\0'+str(size).encode()+b'\0'+member.encode()+b'\0')
    return {'treeSha256':digest.hexdigest(),'fileCount':len(rows),'totalBytes':sum(v[0] for v in rows.values())}

def compile_tree(compiler,source,dest):
    shutil.copytree(source,dest)
    for stem in STEMS:
        output=dest/(stem+'.sla');output.unlink(missing_ok=True)
        subprocess.run([str(compiler.resolve()),stem+'.slaspec'],cwd=dest,check=True)
        if not output.is_file():raise ValueError(f'compiler omitted {output.name}')
    return dest

def replace_literal(text,name,value):
    pattern=r'^'+re.escape(name)+r' = [^\n]*$'
    result,n=re.subn(pattern,lambda _:name+' = '+repr(value),text,flags=re.M)
    if n!=1:raise ValueError(f'expected exactly one literal pin assignment: {name}')
    return result

def pin_text(text,record):
    mapping={pathlib.Path(p['path']).name:p['sha256'] for p in record['patchSeries']}
    block='EXPECTED_PATCHES = {\n'+''.join('    '+repr(k)+':\n        '+repr(v)+',\n' for k,v in sorted(mapping.items()))+'}'
    text,n=re.subn(r'^EXPECTED_PATCHES = \{\n.*?^\}',lambda _:block,text,flags=re.M|re.S)
    if n!=1:raise ValueError('could not locate closed EXPECTED_PATCHES block')
    text=replace_literal(text,'PATCHED_CLOSURE_TREE',record['patched']['resourceClosureTreeSha256'])
    return replace_literal(text,'PATCHED_PACKAGE_TREE',record['patched']['packageTreeSha256WithResourceOverlay'])

def derive(repo,resources,allow_absent=False,compiler=None,upstream_verified=False):
    component=repo/'ThirdParty/SleighNative';package=component/'package';record=json.loads((component/'PATCHED_RESOURCES.json').read_text());old=copy.deepcopy(record)
    archive=json.loads((component/'MATERIALIZATION.json').read_text());rentries=entries(resources)
    if len(rentries)!=29 or any('/' in n for n in rentries):raise ValueError('expected the exact flat 29-file CP1 closure')
    patches=component/'patches/aarch64';members=sorted(patches.glob('*.patch'))
    # Closed set is reviewed in code, not inferred from arbitrary files.
    expected=[f'{n:04d}' for n in range(1,16)]+['0017','0018','0019']
    if [p.name[:4] for p in members]!=expected or len(list(patches.iterdir()))!=18:raise ValueError('patch set must be exactly reviewed 0001 through 0015, 0017, 0018 and 0019')
    record['patchSeries']=[{'path':p.relative_to(component).as_posix(),'sha256':sha(p)} for p in members]
    if old['patched'].get('packageTreeSha256WithResourceOverlay'):
        record.setdefault('previousAcceptedMacOverlay',copy.deepcopy(old['patched']))
        record.setdefault('previousAcceptedMacCompiler',copy.deepcopy(old['compiler']))
    knownbaseline={n:d['baselineSha256'] for n,d in old['patched']['changedFiles'].items()}
    for n in ('AARCH64sme_core.sinc','AARCH64sme_cp1.sinc'):knownbaseline[n]=None
    # This source was unmodified by patches 0001-0014; its shipped hash is pinned
    # in the CP1 baseline provenance rather than derived from the modified file.
    if 'AARCH64sve.sinc' not in knownbaseline:
        provenance=json.loads((component/'CP1_BASELINE.json').read_text());knownbaseline['AARCH64sve.sinc']=provenance['shippedFiles']['AARCH64sve.sinc']
    record['patched']['changedFiles']={n:{'baselineSha256':baseline,'patchedSha256':rentries[n][1]} for n,baseline in sorted(knownbaseline.items())}
    rtree=tree(rentries);record['patched'].update(resourceClosureTreeSha256=rtree['treeSha256'],resourceFileCount=rtree['fileCount'],resourceTotalBytes=rtree['totalBytes'])
    if not package.is_dir():
        if not allow_absent:raise ValueError('package/ is absent; cannot re-derive the full package overlay pin')
        for key in ('packageTreeSha256WithResourceOverlay','packageFileCountWithResourceOverlay','packageTotalBytesWithResourceOverlay'):record['patched'][key]=None
        record['cp1Status']='OFFLINE_CHECKPOINT_MAC_REPIN_REQUIRED'
    else:
        prows=entries(package);ptree=tree(prows)
        if ptree['treeSha256']!=archive['package']['treeSha256'] or archive['package']['treeSha256']!=record['baseline']['packageTreeSha256']:
            raise ValueError('materialized package does not match immutable archive identity; no writes performed')
        for n,d in record['patched']['changedFiles'].items():
            p=package/LANG/n
            if d['baselineSha256'] is None:
                if p.exists():raise ValueError(f'unexpected upstream file: {p}')
            elif not p.is_file() or sha(p)!=d['baselineSha256']:raise ValueError(f'upstream source digest mismatch: {n}')
        overlay=dict(prows);overlay.update({(LANG/n).as_posix():v for n,v in rentries.items()});o=tree(overlay)
        record['patched'].update(packageTreeSha256WithResourceOverlay=o['treeSha256'],packageFileCountWithResourceOverlay=o['fileCount'],packageTotalBytesWithResourceOverlay=o['totalBytes'])
        record['cp1Status']='MAC_PINS_DERIVED_NATIVE_ACCEPTANCE_STILL_REQUIRED'
    if compiler:
        record['compiler']={'path':str(compiler),'script':'ThirdParty/SleighNative/tests/cp1/tooling/rederive_pins.py','sha256':sha(compiler),'upstreamReproducible':True if upstream_verified else None,'scope':'executed compiler identity; native product acceptance is separate'}
    return record

def main():
    p=argparse.ArgumentParser();p.add_argument('--repo',required=True,type=pathlib.Path);p.add_argument('--recompile-with',type=pathlib.Path);p.add_argument('--compiler-identity',type=pathlib.Path);p.add_argument('--allow-unmaterialized-package',action='store_true');p.add_argument('--write',action='store_true');p.add_argument('--report',type=pathlib.Path);a=p.parse_args();repo=a.repo.resolve();component=repo/'ThirdParty/SleighNative';resources=component/'AARCH64'
    with tempfile.TemporaryDirectory(prefix='cp1-repin-') as work:
        work=pathlib.Path(work);used=resources;verified=False
        if a.recompile_with:
            if a.allow_unmaterialized_package:raise ValueError('recompilation requires the materialized archive; do not combine with --allow-unmaterialized-package')
            baseline=component/'package'/LANG
            if not baseline.is_dir():raise ValueError('materialized upstream resources are absent')
            rebuilt=compile_tree(a.recompile_with,baseline,work/'upstream')
            for stem in STEMS:
                n=stem+'.sla'
                if sha(rebuilt/n)!=sha(baseline/n):raise ValueError(f'upstream byte reproducibility failed: {n}; no writes performed')
            verified=True;used=compile_tree(a.recompile_with,resources,work/'owned')
        record=derive(repo,used,a.allow_unmaterialized_package,a.recompile_with or a.compiler_identity,verified)
        tests=repo/'Scripts/tests/test_sleigh_aarch64_patch_contract.py';updated=pin_text(tests.read_text(),record)
        # Compile Python before allowing any write to the contract file.
        compile(updated,str(tests),'exec')
        if a.write:
            if used!=resources:
                for stem in STEMS:shutil.copyfile(used/(stem+'.sla'),resources/(stem+'.sla'))
            (component/'PATCHED_RESOURCES.json').write_text(json.dumps(record,indent=1,sort_keys=True)+'\n')
            tests.write_text(updated)
        result={'wrote':a.write,'upstreamByteReproduced':verified,'nativeAcceptance':False,'record':record}
        text=json.dumps(result,indent=2)+'\n'
        if a.report:a.report.write_text(text)
        print(json.dumps({'wrote':a.write,'upstreamByteReproduced':verified,'status':record['cp1Status'],'resourceTree':record['patched']['resourceClosureTreeSha256'],'packageOverlay':record['patched']['packageTreeSha256WithResourceOverlay']},indent=2))
if __name__=='__main__':main()
