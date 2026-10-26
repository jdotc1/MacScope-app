#!/usr/bin/env python3
"""Typed cache input admission for a newly compiled certificate-signed Release.

Cached dependencies are inputs, never prior app Release qualification. Every
source commit, accepted computation profile and new output keeps its own scope.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

SCOPE = 'accepted-cache-release-inputs'
ENV = 'MACSCOPE_CACHE_RELEASE_ADMISSION'
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
sys.path.insert(0, str(ROOT / 'Scripts/qualification'))
import receipt_device_transition as devices
import native_release_admission as native
import cache_native_release_adoption as computation

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def read(path):
    path=Path(path)
    before=native.D.fields(path)
    if path.stat().st_size>128*1024*1024:raise ValueError('cache metadata receipt exceeds bounded size')
    value=native.read(path)
    if native.D.fields(path)!=before:raise ValueError('cache metadata receipt changed while read')
    return value


def helper(root, relative, name):
    spec = importlib.util.spec_from_file_location(name, Path(root) / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def protected(row):
    computation.require_bound(row)


def snapshot(root):
    """Metadata lease for accepted payloads, including contained dylib links."""
    root=Path(root)
    if root.resolve(strict=True)!=root or not root.is_dir() or root.lstat().st_uid!=os.getuid():
        raise ValueError('cache root must be an ordinary canonical owned directory')
    result={}
    for path in sorted(root.rglob('*')):
        item=path.lstat()
        if item.st_uid!=os.getuid():raise ValueError('foreign cache entry owner')
        link=None
        if stat.S_ISLNK(item.st_mode):
            link=os.readlink(path)
            if Path(link).is_absolute() or not path.resolve(strict=True).is_relative_to(root):
                raise ValueError('cache link escapes accepted payload')
        elif not(stat.S_ISDIR(item.st_mode) or stat.S_ISREG(item.st_mode)):
            raise ValueError('unsupported cache entry type')
        elif stat.S_ISREG(item.st_mode) and item.st_nlink!=1 and item.st_mode&0o222:
            raise ValueError('mutable multiply-linked cache leaf')
        result[str(path.relative_to(root))]={'fields':[getattr(item,n) for n in native.D.FIELDS],'link':link}
    return result


def copy(source, destination):
    source, destination = Path(source), Path(destination)
    if source.is_symlink():
        target=os.readlink(source)
        if Path(target).is_absolute():raise ValueError('absolute cache link')
        before=source.lstat()
        destination.parent.mkdir(parents=True,exist_ok=True)
        destination.parent.chmod(0o700)
        if destination.exists() or destination.is_symlink():destination.unlink()
        destination.symlink_to(target)
        if source.lstat()!=before:raise ValueError('cache link changed during copy')
        return
    if destination.is_symlink():
        raise ValueError('indirect Release staging output')
    before = snapshot(source) if source.is_dir() else native.D.fields(source)
    if source.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        destination.chmod(0o700)
        for child in source.iterdir():
            copy(child, destination / child.name)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.parent.chmod(0o700)
        destination.unlink(missing_ok=True)
        shutil.copy2(source, destination)
    after = snapshot(source) if source.is_dir() else native.D.fields(source)
    if before != after:
        raise ValueError('admitted input changed during controlled copy')


def prepare(repository, donor, derived, output, sealed_source=None):
    repository, donor, derived = [Path(p).resolve(strict=True) for p in (repository, donor, derived)]
    output = Path(output)
    if output.exists() or not output.is_absolute() or repository in output.parents:
        raise ValueError('cache input admission needs a new external receipt')
    output.parent.mkdir(parents=True, exist_ok=True)
    # Genuine computation admission is separately typed. It is not a forged
    # standard Release app/prior QUALIFICATION_INPUTS record.
    native_path = output.parent / 'CACHE_NATIVE_ADMISSION.json'
    if not native_path.exists():
        computation.prepare(repository, donor, derived,
                            macscope_work_root() / 'MacScopeDevLoop.noindex/dependency-views', native_path)
    else:
        accepted_native=read(native_path)
        if accepted_native.get('scope')!=computation.SCOPE:
            raise ValueError('retained native adoption scope differs')
        for row in [*accepted_native['consulted'],accepted_native['archive_receipt'],accepted_native['prior_inputs']]:protected(row)
        for root,prior in accepted_native['view_snapshots'].items():
            if native.D.snapshot(Path(root))!=prior:raise ValueError('retained native view changed')
        if native.D.snapshot(Path(accepted_native['native_build_root']))!=accepted_native['build_snapshot']:
            raise ValueError('retained native linker outputs changed')
        computation.source_updates(native.git_records(repository,'HEAD',native.source_paths(repository)),accepted_native['native_sources'])
    cache = helper(repository, 'Scripts/qualification/dev_dependency_cache.py', 'cache_release_dependencies')
    cache.blob_records = computation.no_reverification
    cache.CACHE.external_file_identity = computation.no_reverification
    view_root = macscope_work_root() / 'MacScopeDevLoop.noindex/dependency-views'
    views, entries, receipts, snapshots = {}, {}, [], {}
    for component in ('ghostty-surface', 'ghostty-vt'):
        key = cache.component_key(component, repository, view_root)
        receipt_path = view_root / component / key / 'VIEW.json'
        receipt = read(receipt_path)
        view, entry = Path(receipt['view']), Path(receipt['entry'])
        if cache.view_receipt_valid(receipt_path, entry, view, component, key) is None:
            raise ValueError('accepted unchanged cache view required: ' + component)
        views[component], entries[component] = str(view), read(entry / 'ENTRY.json')
        receipts.extend([native.record(receipt_path), native.record(entry / 'ENTRY.json')])
        snapshots[str(view)] = snapshot(view)
    settings = {}
    for line in (donor / 'MacScope/DependencyRoots.local.xcconfig').read_text().splitlines():
        if line and not line.startswith('//'):
            key, value = line.split(' = ', 1)
            settings[key] = value
    machokit = helper(repository, 'Scripts/machokit_source_identity.py', 'cache_release_machokit')
    macho_root = Path(settings['MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT'])
    macho_receipt = machokit._admission_receipt(macho_root)
    if read(macho_receipt) != machokit._admission_identity(macho_root):
        raise ValueError('accepted unchanged MachOKit source admission required')
    snapshots[str(macho_root)] = snapshot(macho_root)
    receipts.append(native.record(macho_receipt))
    # Parser roots come from the actual successful donor stage and immutable
    # ENTRY content declarations; source/compiler contracts must still match.
    contract_paths = ('ThirdParty/GhosttyVT','ThirdParty/GhosttySurface','ThirdParty/MachOKit','ThirdParty/REA','ThirdParty/Zig', 'MacScope/ParserEngines', 'Scripts/dependencies',
                      'Scripts/machokit_source_identity.py')
    # The known parser-only SLEIGH consumer delta is covered by the separate
    # computation scope. These nonnative contracts require exact Git objects.
    for path in contract_paths:
        if native.git(repository, 'rev-parse', 'HEAD:' + path) != native.git(donor, 'rev-parse', 'HEAD:' + path):
            raise ValueError('retained nonnative source contract differs: ' + path)
    parser_path=derived/'Build/Intermediates.noindex/MacScope.build/MacScopeParserEngines/STAGED.json'
    parser_before=native.D.fields(parser_path)
    parser_stage=read(parser_path)
    components={'parser-engine-bridge','parser-engine-go-macho','parser-engine-lief','parser-engine-pe-parse'}
    if (set(parser_stage)!={'schema','cache_root','keys','fingerprint'} or parser_stage['schema']!='parser-engines-v1'
            or set(parser_stage['keys'])!=components or parser_stage['cache_root']!=str(cache.DEFAULT_CACHE_ROOT)):
        raise ValueError('closed accepted parser stage contract required')
    if native.D.fields(parser_path)!=parser_before:raise ValueError('parser stage changed while read')
    parser_roots = {}
    for component, key in parser_stage['keys'].items():
        entry = Path(parser_stage['cache_root']) / 'artifacts/v1' / component / key
        manifest, payload = read(entry / 'ENTRY.json'), entry / 'payload'
        records, size = cache.CACHE.payload_records(payload, hash_files=False, allow_hardlinks=True)
        expected = [{k: v for k, v in row.items() if k != 'sha256'} for row in manifest['payload_records']]
        if manifest.get('component')!=component or manifest.get('key')!=key or records != expected or size != manifest['total_bytes']:
            raise ValueError('accepted parser entry structure differs')
        if any(p.lstat().st_mode & 0o222 for p in (payload, *payload.rglob('*'))):
            raise ValueError('parser cache input must remain immutable')
        receipts.append(native.record(entry / 'ENTRY.json'))
        snapshots[str(payload)] = snapshot(payload)
        parser_roots[component] = str(payload)
    if sealed_source is None:
        raise ValueError('new sealed Release source records are required')
    sealed_source=Path(sealed_source).resolve(strict=True)
    records={r['path']:r for r in native.source_manifest(sealed_source/'SOURCE_FILES.json')['files']}
    canonical_manifest=sealed_source/'ThirdParty/MachOKit/materialization/MATERIALIZATION.json'
    # Bind this newly qualified input representation to the recorded canonical
    # source manifest. Byte comparison does not rehash either admitted leaf.
    if (macho_root/'MATERIALIZATION.json').read_bytes()!=canonical_manifest.read_bytes():
        raise ValueError('MachOKit manifest representation differs from canonical source record')
    native_value=read(native_path)
    receipts.append(native.record(native_path))
    surface_rows={r['path']:r for r in entries['ghostty-surface']['payload_records']}
    vt_rows={r['path']:r for r in entries['ghostty-vt']['payload_records']}
    manifest_digests=dict(
        ghostty_surface_manifest_sha256=surface_rows['macos/.macscope-ghostty-surface-manifest']['sha256'],
        ghostty_artifact_manifest_sha256=vt_rows['artifacts/lib/.macscope-ghostty-vt-manifest']['sha256'],
        sleigh_materialization_manifest_sha256=native_value['golden']['materializationManifestSHA256'])
    run=output.parent
    copy(Path(views['ghostty-surface']),run/'dependencies/ghostty-surface/GhosttySurface')
    copy(Path(views['ghostty-vt'])/'artifacts',run/'dependencies/ghostty-vt-qualification/zig-out')
    copy(Path(native_value['staged']['root']),run/'dependencies/sleigh-native-source/SleighNativeSource/materialization')
    copy(macho_root,run/'private-machokit-input')
    copied_roots=[run/'dependencies/ghostty-surface/GhosttySurface',run/'dependencies/ghostty-vt-qualification',
                  run/'dependencies/sleigh-native-source/SleighNativeSource/materialization',run/'private-machokit-input']
    for root in copied_roots:
        for path in reversed([root,*root.rglob('*')]):
            if not path.is_symlink():path.chmod(0o555 if path.is_dir() or path.stat().st_mode&0o111 else 0o444)
        snapshots[str(root)]=snapshot(root)
    value = dict(schema_version=1, scope=SCOPE, source_commit=native.git(repository, 'rev-parse', 'HEAD'),
                 source_tree=native.git(repository, 'rev-parse', 'HEAD^{tree}'),
                 native_admission=str(native_path), manifest_digests=manifest_digests,
                 machokit_manifest_sha256=records['ThirdParty/MachOKit/materialization/MATERIALIZATION.json']['sha256'],
                 sealed_source=str(sealed_source), source_files_receipt=native.record(sealed_source/'SOURCE_FILES.json'),
                 source_provenance_receipt=native.record(sealed_source/'SOURCE_PROVENANCE.json'), views=views, entries=entries, consulted=receipts,
                 snapshots=snapshots, machokit_root=str(macho_root), parser_roots=parser_roots,
                 parser_stage=parser_stage, source_metadata={'donor':str(donor), 'donor_derived':str(derived)})
    native.D.publish(output, value)
    return value


def revalidate(value, *, machokit_renewal=None):
    if value.get('schema_version') != 1 or value.get('scope') != SCOPE:
        raise ValueError('unsupported cache Release input authority')
    renewed=None
    if value.get('machokit_renewal_receipt') or machokit_renewal is not None:
        import machokit_receipt_renewal as renewal
        if value.get('machokit_renewal_receipt'):
            if machokit_renewal is not None:raise ValueError('MachOKit renewal already admitted')
            binding=value.get('machokit_renewal_binding')
            if (binding is None or binding['path']!=value['machokit_renewal_receipt']
                    or renewal.receipt_metadata(Path(binding['path']))!=binding['fields']
                    or binding['fields'][2]&0o222):
                raise ValueError('MachOKit additive renewal proof binding changed')
            proof=read(value['machokit_renewal_receipt'])
            renewed=renewal.validate(proof,value,read)
        else:
            candidates=[row for row in value['consulted'] if row['path']==str(renewal.receipt_path(value['machokit_root']))]
            if len(candidates)!=1:raise ValueError('exact historical MachOKit binding required')
            renewed=candidates[0]
            new_binding={'path':renewed['path'],'fields':renewal.receipt_metadata(Path(renewed['path']))}
            if new_binding==renewed:raise ValueError('MachOKit renewal input did not change')
            document=read(renewed['path'])
    for row in [*value['consulted'], value['source_files_receipt'], value['source_provenance_receipt']]:
        if row!=renewed:protected(row)
    proof_to_publish=None
    for root, prior in value['snapshots'].items():
        observed=snapshot(Path(root))
        if not devices.snapshots_match(root, observed, prior):
            raise ValueError('admitted cache input changed')
        if machokit_renewal is not None and root==value['machokit_root']:
            module=helper(ROOT,'Scripts/machokit_source_identity.py','renewed_machokit_semantics')
            proof_to_publish=renewal.prove(root,renewed,new_binding,document,renewal.semantic_fields(module,root),
                prior,observed,renewal.root_metadata(root),machokit_renewal['source_blobs'],value['machokit_manifest_sha256'])
    if machokit_renewal is not None:
        if proof_to_publish is None:raise ValueError('retained MachOKit payload lease is missing')
        if renewal.receipt_metadata(Path(renewed['path']))!=new_binding['fields']:
            raise ValueError('MachOKit receipt changed during renewal')
        native.D.publish(Path(machokit_renewal['output']),proof_to_publish)
        value['machokit_renewal_receipt']=str(machokit_renewal['output'])
        value['machokit_renewal_binding']=native.record(Path(machokit_renewal['output']))


def inputs(root, environment=None):
    env = os.environ if environment is None else environment
    path = Path(env[ENV])
    value = read(path)
    if value.get('device_transition_receipt'):
        if env.get(devices.ENV)!=value['device_transition_receipt']:
            raise ValueError('device transition differs from cache input authority')
        transition=devices.active()
        if transition is None or transition['target_commit']!=value['source_commit']:
            raise ValueError('device transition belongs to another consumer source')
    revalidate(value)
    q = read(env['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT'])
    if env.get('MACSCOPE_NATIVE_RELEASE_ADMISSION')!=value['native_admission']:
        raise ValueError('ambient native admission differs from cache input authority')
    if Path(root).resolve(strict=True)!=Path(value['sealed_source']):
        raise ValueError('cache source seal belongs to another source root')
    if (q.get('cache_release_admission') != str(path) or q.get('mode') != 'release'
            or q.get('source_identity', {}).get('git_head_commit') != value['source_commit']
            or q.get('source_identity', {}).get('git_head_tree') != value['source_tree']
            or Path(q['build_source_root']) != Path(root).resolve(strict=True)):
        raise ValueError('fresh Release source does not match admitted cache consumer')
    return value, q


def source_digest(path):
    if not os.environ.get(ENV):
        return None
    q = read(os.environ['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT'])
    root = Path(q['build_source_root'])
    value, _ = inputs(root)
    records = {r['path']:r for r in native.source_manifest(root / 'SOURCE_FILES.json')['files']}
    relative = Path(path).relative_to(root).as_posix()
    row = records[relative]
    if Path(path).stat().st_size != row['size']:
        raise ValueError('sealed source leaf size differs from its record')
    return row['sha256']


def admit_current(root, receipt_path, receipt, records, read_json):
    import release_provenance_admission as publication
    value, q = inputs(root)
    lease = publication.Lease()
    for path in (receipt_path, root/'SOURCE_PROVENANCE.json', root/'SOURCE_FILES.json', Path(os.environ[ENV])):
        lease.file(path)
    for row in value['consulted']:
        lease.file(Path(row['path']))
    n = native.admit(root, source_records=records)
    return dict(root=root, receipt_path=receipt_path, receipt=receipt, run=receipt_path.parent,
                records=records, current_release=True, cache_release=True, cache_inputs=value,
                lease=lease, native_helper=native, native=n,
                overlay={'overlay_project_path':str(root/'MacScope/MacScope.xcodeproj/project.xcproj')})


def phase_record(name, env):
    root = Path(env['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT']).parent
    return root / ('CACHE_RELEASE_PHASE_' + name + '_' + env['TARGET_NAME'] + '.json')


def stage_surface(value, destination):
    surface = Path(value['views']['ghostty-surface'])
    artifact = surface/'macos/GhosttyKit.xcframework/macos-arm64'
    rows = {r['path']:r for r in value['entries']['ghostty-surface']['payload_records']}
    manifest_digest = rows['macos/.macscope-ghostty-surface-manifest']['sha256']
    descriptor = {'schema_version':1,'source_manifest_sha256':manifest_digest,'leaves':[]}
    observed = {}
    for role, relative in [('archive','libghostty-internal.a'),('header','Headers/ghostty.h'),('module_map','Headers/module.modulemap')]:
        source = artifact/relative
        copy(source, destination/relative)
        row = rows[source.relative_to(surface).as_posix()]
        descriptor['leaves'].append({'role':role,'relative_path':relative,'sha256':row['sha256']})
        observed[relative] = (relative,row['size'],row['sha256'])
    encoded = canonical(descriptor)
    target = destination/'STAGED_GHOSTTY_SURFACE.json'
    target.write_bytes(encoded)
    observed[target.name] = (target.name,len(encoded),hashlib.sha256(encoded).hexdigest())
    digest = hashlib.sha256()
    for relative,size,sha in sorted(observed.values(),key=lambda row:os.fsencode(row[0])):
        digest.update(f'{relative}\0{size}\0{sha}\0'.encode())
    # The manifest's exact field contract is still checked by the ordinary
    # provenance parser; accepted ENTRY supplies its previously recorded digest.
    writer = helper(ROOT,'Scripts/generate_release_build_provenance.py','cache_release_writer_fields')
    manifest,_ = writer._ghostty_surface_manifest(surface/'macos/.macscope-ghostty-surface-manifest')
    validate_surface_claims(manifest,observed)
    result = dict(ghostty_surface_compilation_condition=writer.GHOSTTY_SURFACE_COMPILATION_CONDITION,
                  ghostty_surface_source_manifest_sha256=manifest_digest,
                  ghostty_surface_source_revision=manifest['source_revision'],ghostty_surface_source_tree=manifest['source_tree'],
                  ghostty_surface_source_sha256=manifest['source_sha256'],ghostty_surface_external_io_abi_version=int(manifest['external_io_abi_version']),
                  ghostty_surface_build_profile_sha256=manifest['build_profile_sha256'],ghostty_surface_staged_tree_sha256=digest.hexdigest(),
                  ghostty_surface_staged_descriptor_relative_path=target.name,ghostty_surface_staged_descriptor_sha256=observed[target.name][2])
    for role,relative in [('archive','libghostty-internal.a'),('header','Headers/ghostty.h'),('module_map','Headers/module.modulemap')]:
        result['ghostty_surface_'+role+'_relative_path']=relative
        result['ghostty_surface_'+role+'_sha256']=observed[relative][2]
    return result


def validate_surface_claims(manifest,observed):
    for relative,field in [('libghostty-internal.a','archive_sha256'),('Headers/ghostty.h','header_sha256'),('Headers/module.modulemap','module_map_sha256')]:
        if observed[relative][2]!=manifest[field]:
            raise ValueError('accepted surface ENTRY leaf differs from manifest: '+relative)


def phase(name):
    env=dict(os.environ)
    root=Path(env['SRCROOT']).parent
    import check_local_signing_policy as policy
    errors=policy.validate_build_environment(env)
    if env.get('CONFIGURATION')!='Release' or env.get('ACTION')!='build' or env.get('CODE_SIGNING_ALLOWED')!='YES':
        errors.append('cache Release inputs require an ordinary signed Release build')
    if errors: raise ValueError('; '.join(errors))
    value,q=inputs(root,env)
    validate_generation(root,Path(env['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT']).parent/'CACHE_GENERATION.json')
    if name=='guard': return
    outputs=[]
    stage_extra={}
    if name in ('rea','machokit','machokit-compiled'):
        # Fresh worker's compiled marker is verified by ordinary provenance,
        # after signing/embedding; no old worker output is substituted.
        pass
    elif name=='surface':
        destination=Path(env['MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT'])
        evidence=stage_surface(value,destination)
        native.D.publish(phase_record(name,env),dict(evidence=evidence,root=str(destination),snapshot=snapshot(destination)))
        return
    elif name=='vt':
        source=Path(value['views']['ghostty-vt'])/'artifacts'
        build_root=Path(env['MACSCOPE_GHOSTTY_VT_BUILD_ROOT'])
        copy(source,build_root/'artifacts')
        stage_extra={'build_root':str(build_root),'build_snapshot':snapshot(build_root),
                     'source_root':str(source),'source_snapshot':snapshot(source)}
        dylib=Path(env['TARGET_BUILD_DIR'])/env['FRAMEWORKS_FOLDER_PATH']/'libghostty-vt.dylib'
        copy((source/'lib/libghostty-vt.dylib').resolve(strict=True),dylib)
        dylib.chmod(0o700)
        identity=env.get('EXPANDED_CODE_SIGN_IDENTITY','')
        if not identity or identity=='-':raise ValueError('certificate signer required')
        subprocess.run(['/usr/bin/codesign','--force','--sign',identity,'--identifier','org.macscope.app.GhosttyVT','--options','runtime','--timestamp=none',str(dylib)],check=True)
        dylib.chmod(0o555)
        outputs.append(native.record(dylib))
    elif name=='parsers':
        destination=Path(env['MACSCOPE_PARSER_ENGINES_ROOT'])
        for component,source in value['parser_roots'].items():copy(source,destination/component)
        (destination/'STAGED.json').write_bytes(canonical(value['parser_stage']))
    else:raise ValueError('unknown cache Release phase')
    revalidate(value)
    marker=phase_record(name,env)
    if marker.exists():marker.unlink()
    native.D.publish(marker,dict(scope=SCOPE,phase=name,outputs=outputs,source_commit=value['source_commit'],**stage_extra))


def retained_evidence(admitted):
    value=admitted['cache_inputs']; revalidate(value)
    path=admitted['run']/'CACHE_RELEASE_PHASE_surface_MacScopeApp.json'
    record=read(path)
    if snapshot(Path(record['root']))!=record['snapshot']:
        raise ValueError('new surface staging changed after its controlled copy')
    return record['evidence']


def specification(text):
    phases = {'Verify certificate-backed signing environment':'guard',
              'Stage verified Ghostty surface build inputs':'surface',
              'Build repository-owned Ghostty VT':'vt', 'Stage cached parser engines':'parsers',
              'Verify canonical embedded REA resource':'rea',
              'Verify exact MachOKit source materialization':'machokit',
              'Verify compiled MachOKit identity in AnalysisWorker':'machokit-compiled'}
    native_phases = {'Build verified native decompiler bridge':'bridge',
                     'Stage verified native decompiler package':'package',
                     'Validate native decompiler bridge golden':'golden'}
    lines=text.splitlines(keepends=True); result=[];name='';index=0
    while index<len(lines):
        line=lines[index]
        if line.startswith('      - name: '):name=line.split(': ',1)[1].strip()
        if line=='        script: |\n' and name in phases.keys()|native_phases.keys():
            result.append(line)
            if name in phases:
                command='/usr/bin/python3 -B "$SRCROOT/../Scripts/qualification/cache_release_inputs.py" phase --phase '+phases[name]
            else:
                command='/usr/bin/python3 -B "$SRCROOT/../Scripts/qualification/native_release_admission.py" phase --repository-root "$SRCROOT/.." --phase '+native_phases[name]
            result.append('          '+command+'\n');index+=1
            while index<len(lines) and (lines[index].startswith('          ') or not lines[index].strip()):index+=1
            continue
        result.append(line);index+=1
    return ''.join(result)


def generation(root):
    from unsigned_development import file_identity
    from project_freshness import generated_project_source_paths
    source=Path(root)/'MacScope'
    paths=('project.yml','DependencyRoots.xcconfig','SigningIdentity.xcconfig','DependencyRoots.local.xcconfig',
           '../ThirdParty/SleighNative/PATCHED_RESOURCES.json','../Scripts/qualification/cache_release_inputs.py')
    return {'inputs':{p:file_identity(source/p) for p in paths},
            'source_paths':generated_project_source_paths(source/'project.yml'),
            'packages':file_identity(source/'LocalPackages',symlink=True),
            'project':file_identity(source/'MacScope.xcodeproj/project.xcproj')}


def validate_generation(root,receipt):
    if generation(root)!=read(receipt):raise ValueError('cache Release generated source/project changed')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('phase');p.add_argument('--phase',required=True)
    args=parser.parse_args()
    phase(args.phase)

if __name__=='__main__':main()
