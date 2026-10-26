#!/usr/bin/env python3
"""Build one real signed Release using explicit already accepted cache inputs."""
from __future__ import annotations
import argparse
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys

TOOLS=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(TOOLS/'Scripts'))
sys.path.insert(0,str(TOOLS/'Scripts/qualification'))
import cache_release_inputs as C
import native_release_admission as N
import receipt_device_transition as devices

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402


def run(command,**kwargs):
    subprocess.run([str(p) for p in command],check=True,**kwargs)


DEPENDENCY_CONTRACTS = ('ThirdParty/GhosttyVT', 'ThirdParty/GhosttySurface',
    'ThirdParty/MachOKit', 'ThirdParty/REA', 'ThirdParty/Zig',
    'MacScope/ParserEngines', 'Scripts/dependencies', 'Scripts/machokit_source_identity.py')
SCANNER_CONSUMER = 'Scripts/dependencies/validate_offline_build_surface.py'


def advance_retained_run(run_root, previous, target, accepted_native, current_native, dependency_changes, *, machokit_renewal=None):
    """Retire the old consumer declarations; keep component evidence historical.

    Callers supply Git source records, never newly hashed dependency payloads.
    The offline scanner is an admission consumer, outside all component producer
    keys. Every other dependency change and every native-input change refuses.
    """
    if not previous or previous == target:
        raise ValueError('source advance requires different exact commits')
    if current_native != accepted_native:
        raise ValueError('source advance changes admitted native computation inputs')
    if set(dependency_changes) - {SCANNER_CONSUMER}:
        raise ValueError('source advance changes admitted dependency producer inputs')
    source = run_root / 'source'
    identity = C.read(source / 'SOURCE_PROVENANCE.json')
    admission = run_root / 'CACHE_RELEASE_INPUTS.json'
    value = C.read(admission)
    if (identity.get('git_head_commit') != previous or value.get('source_commit') != previous
            or value.get('sealed_source') != str(source)):
        raise ValueError('source advance does not name the exact retained consumer')
    C.revalidate(value, machokit_renewal=machokit_renewal)
    qpath = run_root / 'QUALIFICATION_INPUTS.json'
    if qpath.exists():
        q = C.read(qpath)
        if (q.get('source_identity', {}).get('git_head_commit') != previous
                or q.get('build_source_root') != str(source)
                or q.get('cache_release_admission') != str(admission)):
            raise ValueError('retained qualification declaration belongs to another source')
    history = run_root / ('source-advance-' + previous + '-to-' + target)
    retired = run_root / ('source-before-' + previous)
    if history.exists() or retired.exists():
        raise ValueError('source advance history already exists; preserve it for recovery')
    declarations = [admission, qpath, run_root / 'CACHE_GENERATION.json',
                    *sorted(run_root.glob('CACHE_RELEASE_PHASE_*.json'))]
    for path in declarations:
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise ValueError('source advance declaration is not an ordinary file')
    history.mkdir(mode=0o700)
    N.D.publish(history / 'ADVANCE.json', dict(previous_commit=previous, target_commit=target,
        previous_source=str(source), retired_source=str(retired),
        consumer_changes=sorted(dependency_changes), native_inputs_reused=True,
        declarations=[p.name for p in declarations if p.exists()]))
    # Rename rather than discard: old declarations and generated-product phase
    # records cannot accidentally qualify the next source or new app products.
    for path in declarations:
        if path.exists():
            path.rename(history / path.name)
    source.rename(retired)
    return value, retired


def apply_pattern_adapter(root,receipt,environment,settings,qualification,build_settings):
    root,receipt=Path(root),Path(receipt)
    if (not root.is_absolute() or root.resolve(strict=True)!=root or not root.is_dir()
            or root.stat().st_uid!=os.getuid()):
        raise ValueError('retained pattern adapter root must be canonical and owned')
    if any(token in str(root) for token in ('"','$','//','\\','\n','\r')):
        raise ValueError('pattern adapter root cannot be represented in dependency configuration')
    # Reuse the owner's accepted producer handoff. The project performs the
    # existing presence-only archive/module/header gate; never rebuild or hash.
    authority=N.record(receipt)
    key='MACSCOPE_PATTERN_ADAPTER_ROOT'
    environment[key]=settings[key]=str(root)
    qualification['retained_pattern_adapter']=dict(root=str(root),accepted_producer_receipt=authority,
        scope='retained-pattern-adapter-input; producer evidence reused')
    build_settings.append(key+'='+str(root))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('source-root','work-root','cache-release-admission','prepared-repository','prepared-derived-data','integration-ref','integration-commit'):
        p.add_argument('--'+name,required=True)
    p.add_argument('--mode',choices=('release',),required=True)
    p.add_argument('--pattern-adapter-root',required=True)
    p.add_argument('--pattern-adapter-receipt',required=True)
    p.add_argument('--admit-machokit-renewal', action='store_true', help='Admit exact typed MachOKit receipt renewal using the retained payload metadata lease')
    p.add_argument('--admit-device-transition', action='store_true', help='Record a coherent device-only metadata transition before retained source advance')
    p.add_argument('--advance-source-from', help='Preserve and advance a completed run with unchanged component inputs')
    p.add_argument('--repair-source-from', help='Exact previous local tooling commit to advance in this same run')
    p.add_argument('--dependency-cache-root',default=str(macscope_work_root() / 'MacScopeQualificationCache-20260920'))
    p.add_argument('--verification-cache-root',default=None)
    p.add_argument('--signing',choices=('development',),default='development')
    a=p.parse_args()
    if a.admit_machokit_renewal and not a.advance_source_from:
        p.error('MachOKit renewal requires an explicit retained source advance')
    if a.admit_device_transition and not a.advance_source_from:
        p.error('device transition requires an explicit retained source advance')
    if a.advance_source_from and a.repair_source_from:
        p.error('choose either source advance or tooling repair')
    repository=Path(a.source_root).resolve(strict=True)
    work=Path(a.work_root).resolve(strict=True)
    admission=Path(a.cache_release_admission)
    run_root=admission.parent
    if (not admission.is_absolute() or admission.name!='CACHE_RELEASE_INPUTS.json'
            or run_root.parent!=work/'runs' or not run_root.name.startswith('run.')
            or repository==work or repository in work.parents):
        raise ValueError('cache Release run must be an external named run under its work root')
    if any(os.environ.get(k) for k in ('CI','GITHUB_ACTIONS','MACSCOPE_DEV_UNSIGNED','MACSCOPE_ISOLATED_CI_ADHOC_SIGNING')):
        raise ValueError('cache Release route requires local certificate-backed signing')
    head=N.git(repository,'rev-parse','HEAD')
    if head!=a.integration_commit or N.git(repository,'rev-parse',a.integration_ref)!=head:
        raise ValueError('source HEAD and genuine integration ref must name the exact candidate')
    run_root.mkdir(mode=0o700,parents=True,exist_ok=True)
    lock=macscope_work_root() / '.macscope-heavy-gate.lock'
    with lock.open('a') as stream:
        run([sys.executable,TOOLS/'Scripts/qualification/heavy_gate_lock.py','acquire','--lock',lock,'--fd',stream.fileno(),
             '--pid',os.getpid(),'--work-root',work,'--integration-ref',a.integration_ref,'--mode','release','--run-root',run_root],pass_fds=(stream.fileno(),))
        try:
            execute(a,repository,run_root,admission)
        finally:
            run([sys.executable,TOOLS/'Scripts/qualification/heavy_gate_lock.py','release','--lock',lock,'--pid',os.getpid()])


def execute(a,repository,run_root,admission):
    env=dict(os.environ)
    env['PYTHONDONTWRITEBYTECODE']='1'
    env['DEVELOPER_DIR']=env.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    env['SDKROOT']=subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    # This is the first seal of a newly reviewed Git identity. The canonical
    # exporter reuses accepted per-blob digests; never walk/verify the export.
    source=run_root/'source'
    retained_inputs=None
    if a.advance_source_from:
        run(['git', '-C', repository, 'merge-base', '--is-ancestor', a.advance_source_from, a.integration_commit])
        old = C.read(admission)
        native_inputs = N.read(old['native_admission'])
        current = N.git_records(repository, 'HEAD', N.source_paths(repository))
        changes = N.git(repository, 'diff', '--name-only', a.advance_source_from,
                        a.integration_commit, '--', *DEPENDENCY_CONTRACTS).splitlines()
        if old.get('device_transition_receipt'):
            if a.admit_device_transition:
                raise ValueError('retained consumer already carries a device audit; continue it without readmission')
            if current != native_inputs['native_sources'] or set(changes)-{SCANNER_CONSUMER}:
                raise ValueError('device audit continuation cannot admit changed component inputs')
            transition=devices.successor(Path(old['device_transition_receipt']),a.advance_source_from,
                                         a.integration_commit)
            transition_path=run_root/('RECEIPT_DEVICE_TRANSITION.'+a.integration_commit+'.json')
            N.D.publish(transition_path,transition)
            env[devices.ENV]=os.environ[devices.ENV]=str(transition_path)
        if a.admit_device_transition:
            # Contract checks precede any additive admission. This does not
            # permit a new native producer, archive, or dependency source input.
            if current != native_inputs['native_sources'] or set(changes)-{SCANNER_CONSUMER}:
                raise ValueError('device transition cannot admit changed component inputs')
            rows=[*old['consulted'],old['source_files_receipt'],old['source_provenance_receipt'],
                  *native_inputs['consulted'],native_inputs['archive_receipt'],native_inputs['prior_inputs']]
            roots=[*old['snapshots'],*native_inputs['view_snapshots'],native_inputs['native_build_root']]
            entries={row['path']:old['entries'][component]
                     for row in old['consulted'] for component in old['entries']
                     if row['path'].endswith('/'+component+'/'+old['entries'][component]['key']+'/ENTRY.json')}
            if len(entries)!=len(old['entries']):
                raise ValueError('embedded entry declarations lack exact consulted paths')
            transition=devices.declaration(rows,roots,entries,previous=a.advance_source_from,
                                           target=a.integration_commit,read=C.read)
            transition_path=run_root/('RECEIPT_DEVICE_TRANSITION.'+a.integration_commit+'.json')
            N.D.publish(transition_path,transition)
            env[devices.ENV]=os.environ[devices.ENV]=str(transition_path)
        renewal=None
        if a.admit_machokit_renewal:
            path='Scripts/machokit_source_identity.py'
            renewal=dict(output=str(run_root/('MACHOKIT_RECEIPT_RENEWAL.'+a.integration_commit+'.json')),
                source_blobs=[N.git(repository,'rev-parse',ref+':'+path)
                              for ref in (a.advance_source_from,a.integration_commit)])
        retained_inputs, retired = advance_retained_run(run_root, a.advance_source_from,
            a.integration_commit, native_inputs['native_sources'], current, changes,machokit_renewal=renewal)
        if a.admit_device_transition or old.get('device_transition_receipt'):
            retained_inputs['device_transition_receipt']=str(transition_path)
    elif source.exists() and a.repair_source_from:
        previous=C.read(source/'SOURCE_PROVENANCE.json')
        if previous['git_head_commit'] != a.repair_source_from or a.repair_source_from == a.integration_commit:
            raise ValueError('source repair requires the exact different prior local tooling commit')
        run(['git','-C',repository,'merge-base','--is-ancestor',a.repair_source_from,a.integration_commit])
        if (run_root/'QUALIFICATION_INPUTS.json').exists():
            raise ValueError('source repair requires explicit handling of already admitted qualification inputs')
        if admission.exists():
            retained_inputs=C.read(admission)
            C.revalidate(retained_inputs)
            if retained_inputs['source_commit']!=a.repair_source_from:
                raise ValueError('retained dependency admission names another prior consumer')
            preserved=run_root/('CACHE_RELEASE_INPUTS.before-'+a.repair_source_from+'.json')
            if preserved.exists():raise ValueError('prior admission preservation path already exists')
            shutil.copy2(admission,preserved)
        retired=run_root/('source-before-'+a.repair_source_from)
        if retired.exists():raise ValueError('prior sealed source preservation path already exists')
        source.rename(retired)
    else:
        retired=None
    if not source.exists():
        cache=Path(a.verification_cache_root or str(Path(a.dependency_cache_root)/'verification.noindex'))/'source-records'
        run([sys.executable,TOOLS/'Scripts/source_export_provenance.py','git-stage','--repository-root',repository,
             '--destination',source,'--integration-ref',a.integration_ref,'--expected-commit',a.integration_commit,'--record-cache',cache],env=env)
    if retired is not None and (run_root/'DerivedData').exists():
        # Reuse accepted identical Git leaves and retain compiler-visible mtimes.
        # Only newly changed tooling leaves come from this first new source seal.
        prior={row['path']:row for row in N.source_manifest(retired/'SOURCE_FILES.json')['files']}
        current=N.source_manifest(source/'SOURCE_FILES.json')['files']
        for row in current:
            old=prior.get(row['path'])
            if old is None or tuple(old.get(k) for k in ('blob_oid','mode','sha256','size')) != tuple(row.get(k) for k in ('blob_oid','mode','sha256','size')):
                continue
            origin=retired/row['path'];target=source/row['path']
            if origin.is_symlink() or not origin.is_file():continue
            before=N.D.fields(origin)
            target.unlink();shutil.copy2(origin,target)
            if N.D.fields(origin)!=before:raise ValueError('accepted source changed during repair copy')
    identity=C.read(source/'SOURCE_PROVENANCE.json')
    if identity['git_head_commit']!=a.integration_commit:
        raise ValueError('retained run source differs; preserve it and update this run through source repair')
    if retained_inputs is not None:
        # Tooling-only repair changes the consumer seal; accepted computation
        # and dependency source contracts must remain the exact same Git leaves.
        records={r['path']:r for r in N.source_manifest(source/'SOURCE_FILES.json')['files']}
        native_inputs=N.read(retained_inputs['native_admission'])
        paths=N.source_paths(repository)
        if set(paths)!=set(native_inputs['native_sources']) or any(
                {k:records[path][k] for k in ('mode','blob_oid')}!=native_inputs['native_sources'][path]
                for path in paths):
            raise ValueError('source repair changes an admitted native computation input')
        contracts=('ThirdParty/GhosttyVT','ThirdParty/GhosttySurface','ThirdParty/MachOKit',
                   'ThirdParty/REA','ThirdParty/Zig','MacScope/ParserEngines',
                   'Scripts/dependencies','Scripts/machokit_source_identity.py')
        for path in (() if a.advance_source_from else contracts):
            if N.git(repository,'rev-parse',a.repair_source_from+':'+path)!=N.git(repository,'rev-parse',a.integration_commit+':'+path):
                raise ValueError('source repair changes an admitted dependency source contract: '+path)
        retained_inputs.update(source_commit=a.integration_commit,source_tree=identity['git_head_tree'],
                               source_files_receipt=N.record(source/'SOURCE_FILES.json'),
                               source_provenance_receipt=N.record(source/'SOURCE_PROVENANCE.json'))
        retained_inputs.setdefault('consumer_repairs',[]).append(dict(previous_commit=a.advance_source_from or a.repair_source_from,
                                                                    current_commit=a.integration_commit))
        C.revalidate(retained_inputs)
        if admission.exists():admission.unlink()
        N.D.publish(admission,retained_inputs)
    if not admission.exists():
        old=dict(os.environ)
        os.environ.update(env)
        try:C.prepare(repository,Path(a.prepared_repository),Path(a.prepared_derived_data),admission,sealed_source=source)
        finally:os.environ.clear();os.environ.update(old)
    value=C.read(admission)
    if value.get('device_transition_receipt'):
        env[devices.ENV]=os.environ[devices.ENV]=value['device_transition_receipt']
    C.revalidate(value)
    native=C.read(value['native_admission'])
    q=dict(schema_version=4,mode='release',build_source_root=str(source),dependency_cache_root=a.dependency_cache_root,
           dependency_network_allowed=False,dependency_network_used=False,source_identity=identity,
           ghostty_source_dir=str(run_root/'dependencies/ghostty-vt-qualification'),
           ghostty_surface_source_dir=str(run_root/'dependencies/ghostty-surface/GhosttySurface'),
           ghostty_surface_artifact_root=str(run_root/'dependencies/ghostty-surface/GhosttySurface/macos/GhosttyKit.xcframework'),
           sleigh_materialization_root=str(run_root/'dependencies/sleigh-native-source/SleighNativeSource/materialization'),
           zig_executable=str(source/'ThirdParty/Zig/zig-0.16.0/zig'),cache_release_admission=str(admission),**value['manifest_digests'])
    receipt=run_root/'QUALIFICATION_INPUTS.json'
    local=source/'MacScope/LocalPackages'
    macho=run_root/'private-machokit-input'
    if not local.exists():local.symlink_to(macho,target_is_directory=True)
    elif local.resolve()!=macho:raise ValueError('unexpected package input link')
    settings=dict(MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT=str(run_root/'dependencies/ghostty-surface'),
                  MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR=q['ghostty_surface_source_dir'],
                  MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT=q['ghostty_surface_artifact_root'],
                  MACSCOPE_GHOSTTY_SURFACE_ENABLED='MACSCOPE_FULL_GHOSTTY_SURFACE',
                  MACSCOPE_SLEIGH_COMPONENT_ROOT=str(source/'ThirdParty/SleighNative'),
                  MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=str(run_root/'dependencies/sleigh-native-source/SleighNativeSource'),
                  MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=q['sleigh_materialization_root'],
                  MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=str(macho),MACSCOPE_PARSER_ENGINE_CACHE_ROOT=a.dependency_cache_root)
    pattern_settings=[]
    apply_pattern_adapter(a.pattern_adapter_root,a.pattern_adapter_receipt,env,settings,q,pattern_settings)
    if not receipt.exists():N.D.publish(receipt,q)
    elif C.read(receipt)!=q:raise ValueError('retained qualification identity differs')
    config=source/'MacScope/DependencyRoots.local.xcconfig'
    payload=''.join(f'{k} = {v}\n' for k,v in settings.items())
    if not config.exists():config.write_text(payload)
    elif config.read_text()!=payload:raise ValueError('retained dependency paths differ')
    from generate_xcode_json_project import generate
    from project_freshness import generated_project_source_paths
    from unsigned_development import file_identity
    generation_paths=('project.yml','DependencyRoots.xcconfig','SigningIdentity.xcconfig','DependencyRoots.local.xcconfig','../ThirdParty/SleighNative/PATCHED_RESOURCES.json')
    before_inputs={p:file_identity(source/'MacScope'/p) for p in generation_paths}
    before=generated_project_source_paths(source/'MacScope/project.yml')
    generate(source/'MacScope',cache_release=True)
    if before_inputs!={p:file_identity(source/'MacScope'/p) for p in generation_paths}:raise ValueError('generation inputs changed during generation')
    if before!=generated_project_source_paths(source/'MacScope/project.yml'):raise ValueError('source membership changed during generation')
    generation=run_root/'CACHE_GENERATION.json'
    if generation.exists():generation.unlink()
    N.D.publish(generation,C.generation(source))
    env.update({C.ENV:str(admission),'MACSCOPE_NATIVE_RELEASE_ADMISSION':value['native_admission'],
                'MACSCOPE_QUALIFICATION_INPUTS_RECEIPT':str(receipt),'MACSCOPE_DEBUG_SOURCE_IDENTITY':'source-qualified'})
    command=['/usr/bin/nice','-n','5','/usr/bin/xcodebuild','build','-project',source/'MacScope/MacScope.xcodeproj',
             '-scheme','MacScopeApp','-configuration','Release','-destination','platform=macOS,arch=arm64',
             '-derivedDataPath',run_root/'DerivedData','-jobs','4','-disableAutomaticPackageResolution',
             '-onlyUsePackageVersionsFromResolvedFile','COMPILER_INDEX_STORE_ENABLE=NO',
             'COMPILATION_CACHE_ENABLE_CACHING=YES',
             'COMPILATION_CACHE_CAS_PATH='+str(macscope_work_root() / 'MacScopeDevLoop.noindex/compilation-cache'),
             C.ENV+'='+str(admission),'MACSCOPE_NATIVE_RELEASE_ADMISSION='+value['native_admission'],
             'MACSCOPE_QUALIFICATION_INPUTS_RECEIPT='+str(receipt),'MACSCOPE_DEBUG_SOURCE_IDENTITY=source-qualified',
             'MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT='+native['native_build_root'],
             '-showBuildTimingSummary']
    command.extend(pattern_settings)
    if env.get(devices.ENV):command.append(devices.ENV+'='+env[devices.ENV])
    with (run_root/'xcode-release-build.log').open('a') as log:
        run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
    app=run_root/'DerivedData/Build/Products/Release/MacScope.app'
    validation=[sys.executable,source/'Scripts/reconstruction/validate_qualification_product_identity.py','validate-build',
                '--receipt',receipt,'--run-root',run_root,'--derived-data-root',run_root/'DerivedData',
                '--build-source-root',source,'--dependency-cache-root',a.dependency_cache_root,'--expected-mode','release',
                '--expected-integration-ref',a.integration_ref,'--expected-integration-commit',a.integration_commit,
                '--expected-integration-tree',identity['git_head_tree'],'--app-bundle',app,'--expected-configuration','Release']
    with (run_root/'product-identity.log').open('a') as log:run(validation,env=env,stdout=log,stderr=subprocess.STDOUT)
    print('Release build and product identity complete: '+str(app))
    print('Source-qualified local tooling commit: '+identity['git_head_commit'])
    print('No installation or prior app Release acceptance is implied.')

if __name__=='__main__':main()
