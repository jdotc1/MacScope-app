"""Focused synthetic acceptance for the new typed cache Release boundary."""
from pathlib import Path
import importlib.util
import os
import sys
import tempfile
import unittest
import json
import hashlib
from unittest.mock import patch
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Scripts/qualification'))
sys.path.insert(0,str(ROOT/'Scripts/lib'))
from work_root import existing_work_root
import cache_release_inputs as cache
import cache_native_release_adoption as native
import cache_release_build as release
import receipt_device_transition as devices
import machokit_receipt_renewal as machokit_renewal

class CacheReleaseInputContractTests(unittest.TestCase):
    def test_typed_source_surface_and_staging_boundaries(self):
        old={native.CONSUMER:{'mode':'100644','blob_oid':native.CONSUMER_DELTA[0]},'compiled.cpp':{'mode':'100644','blob_oid':'a'*40}}
        current={**old,native.CONSUMER:{'mode':'100644','blob_oid':native.CONSUMER_DELTA[1]}}
        self.assertEqual(set(native.source_updates(current,old)),{native.CONSUMER})
        with self.assertRaises(ValueError):native.source_updates({**current,'compiled.cpp':{'mode':'100644','blob_oid':'b'*40}},old)
        observed={'libghostty-internal.a':('libghostty-internal.a',3,'a'*64),'Headers/ghostty.h':('Headers/ghostty.h',2,'b'*64),'Headers/module.modulemap':('Headers/module.modulemap',1,'c'*64)}
        manifest={'archive_sha256':'a'*64,'header_sha256':'b'*64,'module_map_sha256':'c'*64}
        cache.validate_surface_claims(manifest,observed)
        with self.assertRaises(ValueError):cache.validate_surface_claims({**manifest,'archive_sha256':'d'*64},observed)
        text=(ROOT/'MacScope/project.yml').read_text()
        transformed=cache.specification(text)
        self.assertIn('Generate sealed Release build provenance',transformed)
        self.assertIn('generate_release_build_provenance.py',transformed)
        self.assertIn('--phase machokit-compiled',transformed)
        self.assertFalse(any(line.strip() == 'CODE_SIGNING_ALLOWED: NO' for line in transformed.splitlines()))
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();leaf=root/'admitted';leaf.write_text('old')
            value={'schema_version':1,'scope':cache.SCOPE,'consulted':[],
                   'source_files_receipt':cache.native.record(leaf),'source_provenance_receipt':cache.native.record(leaf),
                   'snapshots':{str(root):cache.snapshot(root)},'native_admission':str(root/'native.json'),
                   'sealed_source':str(root),'source_commit':'1'*40,'source_tree':'2'*40}
            q={'cache_release_admission':str(root/'admission.json'),'mode':'release','build_source_root':str(root),
               'source_identity':{'git_head_commit':'1'*40,'git_head_tree':'2'*40}}
            env={cache.ENV:str(root/'admission.json'),'MACSCOPE_QUALIFICATION_INPUTS_RECEIPT':str(root/'Q.json'),
                 'MACSCOPE_NATIVE_RELEASE_ADMISSION':value['native_admission']}
            with patch.object(cache,'read',side_effect=[value,q]):
                self.assertEqual(cache.inputs(root,env)[0]['scope'],cache.SCOPE)
            with patch.object(cache,'read',side_effect=[value,{**q,'source_identity':{'git_head_commit':'9'*40,'git_head_tree':'2'*40}}]):
                with self.assertRaises(ValueError):cache.inputs(root,env)
            with patch.object(cache,'read',side_effect=[value,q]):
                with self.assertRaises(ValueError):cache.inputs(root,{**env,'MACSCOPE_NATIVE_RELEASE_ADMISSION':str(root/'foreign.json')})
            with patch.object(cache,'read',side_effect=[value,q]):
                with self.assertRaises(ValueError):cache.inputs(root.parent,env)
            sys.path.insert(0,str(ROOT))
            from Scripts.reconstruction import validate_qualification_product_identity as validator
            from Scripts.qualification import cache_release_inputs as validator_cache
            authority=SimpleNamespace(cache_release_inputs=value,run_root=root,source_commit='1'*40,derived_data_root=root/'DerivedData')
            foreign={'scope':cache.SCOPE,'phase':'vt','source_commit':'1'*40,'outputs':[{'path':str(root/'foreign.app/Contents/Frameworks/libghostty-vt.dylib')}]}
            with patch.object(validator_cache,'revalidate'),patch.object(validator_cache,'read',return_value=foreign):
                with self.assertRaises(validator.ProductIdentityError):validator._validate_ghostty_vt_products(authority,root/'MacScope.app','Release')
            with patch.object(validator,'validate_qualification_inputs',return_value=authority):
                with self.assertRaises(validator.ProductIdentityError):validator.validate_qualification_build(SimpleNamespace(expected_mode='release',expected_configuration='Release',app_bundle=root/'foreign.app'))
            leaf.write_text('changed')
            with self.assertRaises(ValueError):cache.revalidate(value)

    def test_contained_dylib_links_and_controlled_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();source=root/'source';source.mkdir()
            (source/'real.dylib').write_text('accepted')
            (source/'alias.dylib').symlink_to('real.dylib')
            before=cache.snapshot(source)
            destination=root/'copy';cache.copy(source,destination)
            self.assertEqual(os.readlink(destination/'alias.dylib'),'real.dylib')
            self.assertEqual(cache.snapshot(source),before)
            (source/'escape').symlink_to('../outside')
            (root/'outside').write_text('foreign')
            with self.assertRaises(ValueError):cache.snapshot(source)

class RetainedSourceAdvanceTests(unittest.TestCase):
    def test_preserves_history_and_derived_data_before_source_advance(self):
        self.assertTrue(callable(getattr(release,"advance_retained_run",None)),"retained source advance is missing")
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve(); source=root/'source';source.mkdir()
            previous='1'*40; target='2'*40
            (source/'SOURCE_PROVENANCE.json').write_text(json.dumps({'git_head_commit':previous}))
            (source/'SOURCE_FILES.json').write_text('{"files":[]}')
            (source/'unchanged.swift').write_text('accepted')
            derived=root/'DerivedData';derived.mkdir();product=derived/'retained.o';product.write_text('warm')
            before=product.stat()
            q={'source_identity':{'git_head_commit':previous},'build_source_root':str(source),
               'cache_release_admission':str(root/'CACHE_RELEASE_INPUTS.json')}
            (root/'QUALIFICATION_INPUTS.json').write_text(json.dumps(q))
            (root/'CACHE_GENERATION.json').write_text('{"old":"generation"}')
            (root/'CACHE_RELEASE_PHASE_surface_MacScopeApp.json').write_text('{"old":"phase"}')
            native={'native.cpp':{'mode':'100644','blob_oid':'a'*40}}
            value={'schema_version':1,'scope':cache.SCOPE,'source_commit':previous,
                   'sealed_source':str(source),'consulted':[],'snapshots':{},
                   'source_files_receipt':cache.native.record(source/'SOURCE_FILES.json'),
                   'source_provenance_receipt':cache.native.record(source/'SOURCE_PROVENANCE.json')}
            (root/'CACHE_RELEASE_INPUTS.json').write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError,'native'):
                release.advance_retained_run(root,previous,target,native,{},[])
            self.assertTrue((root/'QUALIFICATION_INPUTS.json').exists())
            with self.assertRaisesRegex(ValueError,'dependency'):
                release.advance_retained_run(root,previous,target,native,native,['Scripts/dependencies/build.sh'])
            self.assertTrue(source.exists())
            kept,retired=release.advance_retained_run(root,previous,target,native,native,
                ['Scripts/dependencies/validate_offline_build_surface.py'])
            history=root/('source-advance-'+previous+'-to-'+target)
            self.assertEqual(json.loads((history/'QUALIFICATION_INPUTS.json').read_text()),q)
            self.assertEqual(json.loads((history/'CACHE_RELEASE_INPUTS.json').read_text())['source_commit'],previous)
            self.assertEqual((retired/'unchanged.swift').read_text(),'accepted')
            self.assertTrue((history/'CACHE_GENERATION.json').exists())
            self.assertTrue((history/'CACHE_RELEASE_PHASE_surface_MacScopeApp.json').exists())
            self.assertFalse(source.exists())
            self.assertFalse((root/'QUALIFICATION_INPUTS.json').exists())
            self.assertEqual(kept['source_commit'],previous)
            self.assertEqual(product.read_text(),'warm')
            self.assertEqual(product.stat(),before)
            self.assertEqual(json.loads((history/'ADVANCE.json').read_text())['target_commit'],target)

class DeviceTransitionTests(unittest.TestCase):
    def test_coherent_device_transition_retains_all_other_binding_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();entry=root/'ENTRY.json';entry.write_text('{"key":"accepted"}')
            old=[10,20,33024,1,18,30,40];current=[11,*old[1:]]
            row={'path':str(entry),'fields':old}
            value=devices.declaration([row],[str(root)],{str(entry):{'key':'accepted'}},
                previous='a'*40,target='b'*40,observe=lambda p:current)
            self.assertEqual((value['old_device'],value['new_device']),(10,11))
            self.assertTrue(devices.fields_match(entry,current,old,transition=value))
            for index in range(1,7):
                drift=current.copy();drift[index]+=1
                with self.subTest(field=index):
                    with self.assertRaisesRegex(ValueError,'nondevice'):
                        devices.declaration([row],[str(root)],{},previous='a',target='b',observe=lambda p:drift)
                    self.assertFalse(devices.fields_match(entry,drift,old,transition=value))
            with self.assertRaisesRegex(ValueError,'entry declaration'):
                devices.declaration([row],[str(root)],{str(entry):{'key':'different'}},
                    previous='a',target='b',observe=lambda p:current)
            other=root/'other';other.write_text('x')
            with self.assertRaisesRegex(ValueError,'inconsistent'):
                devices.declaration([row,{'path':str(other),'fields':old}],[str(root)],{},
                    previous='a',target='b',observe=lambda p:current if p==str(entry) else [12,*old[1:]])
            self.assertFalse(devices.fields_match(other,current,old,transition=value))
            link=root/'link';link.symlink_to(entry)
            with self.assertRaisesRegex(ValueError,'canonical'):
                devices.metadata(link)
            self.assertTrue(devices.snapshots_match(root,{},{}))

    def test_runtime_reuse_rejects_snapshot_drift_and_foreign_source_authority(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();leaf=root/'accepted';leaf.write_text('receipt')
            current=devices.metadata(leaf);old=[current[0]+1,*current[1:]]
            value=devices.declaration([{'path':str(leaf),'fields':old}],[str(root)],{},
                previous='a'*40,target='b'*40,observe=lambda p:current)
            audit=root/'transition.json';audit.write_text(json.dumps(value));audit.chmod(0o400)
            with patch.dict(os.environ,{devices.ENV:str(audit)}):
                native.require_bound({'path':str(leaf),'fields':old})
                self.assertTrue(devices.snapshots_match(root,{'accepted':current},{'accepted':old}))
                for field in range(1,7):
                    changed=current.copy();changed[field]+=1
                    self.assertFalse(devices.snapshots_match(root,{'accepted':changed},{'accepted':old}))
                self.assertFalse(devices.snapshots_match(root,{'other':current},{'accepted':old}))
                document={'device_transition_receipt':str(audit),'source_commit':'c'*40}
                with patch.object(cache,'read',return_value=document):
                    with self.assertRaisesRegex(ValueError,'another consumer'):
                        cache.inputs(root,{cache.ENV:str(root/'inputs.json'),devices.ENV:str(audit)})
                leaf.write_text('changed')
                with self.assertRaisesRegex(ValueError,'input changed'):
                    native.require_bound({'path':str(leaf),'fields':old})

    def test_cache_native_admission_reads_original_declarations_through_device_audit(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();build=root/'native-build';build.mkdir()
            archive=root/'archive.json';archive.write_text('{"archive":"accepted"}')
            prior=root/'prior.json';prior.write_text('{"golden":"historical"}')
            rows=[]
            for path in (archive,prior):
                fields=devices.metadata(path);fields[0]+=1
                rows.append({'path':str(path),'fields':fields})
            transition=devices.declaration(rows,[str(build)],{},previous='a',target='b')
            audit=root/'transition.json';audit.write_text(json.dumps(transition));audit.chmod(0o400)
            value={'toolchain':{},'native_sources':{},'consulted':[],
                   'archive_receipt':rows[0],'prior_inputs':rows[1],
                   'view_snapshots':{},'native_build_root':str(build),'build_snapshot':{}}
            with patch.dict(os.environ,{devices.ENV:str(audit)}),patch.object(native.N,'source_paths',return_value=[]):
                result=native.admit(root,{'CONFIGURATION':'Release','SWIFT_OPTIMIZATION_LEVEL':'-O'},value,root/'native.json',source_records={})
            self.assertEqual(result['archive'],{'archive':'accepted'})
            self.assertEqual(result['prior'],{'golden':'historical'})
            self.assertEqual(json.loads(archive.read_text()),{'archive':'accepted'})

class DeviceAuditContinuationTests(unittest.TestCase):
    def test_successor_audit_preserves_original_and_refuses_prior_or_binding_drift(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            root=Path(temp).resolve();leaf=root/'accepted.json';leaf.write_text('{}')
            fields=devices.metadata(leaf);old=[fields[0]+1,*fields[1:]]
            original=devices.declaration([{'path':str(leaf),'fields':old}],[str(root)],{},
                previous='a',target='b',observe=lambda p:fields)
            prior=root/'prior.json';prior.write_text(json.dumps(original));prior.chmod(0o400)
            before=prior.read_bytes()
            successor=devices.successor(prior,'b','c')
            self.assertEqual(successor['bindings'],original['bindings'])
            self.assertEqual(successor['target_commit'],'c')
            self.assertEqual(prior.read_bytes(),before)
            with self.assertRaisesRegex(ValueError,'exact prior consumer'):devices.successor(prior,'wrong','c')
            current=root/'current.json';current.write_text(json.dumps(successor));current.chmod(0o400)
            with patch.dict(os.environ,{devices.ENV:str(current)}):
                self.assertTrue(devices.fields_match(leaf,fields,old))
                prior.chmod(0o600);prior.write_text('{}');prior.chmod(0o400)
                with self.assertRaisesRegex(ValueError,'prior device transition'):devices.active()

class RetainedNativePackageCopyTests(unittest.TestCase):
    def test_replaces_readonly_nested_package_without_mutating_admitted_source(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            root=Path(temp).resolve();source=root/'source';source.mkdir()
            (source/'nested').mkdir();leaf=source/'nested/header.hh';leaf.write_text('accepted')
            leaf.chmod(0o444);(source/'nested').chmod(0o555);source.chmod(0o555)
            destination=root/'destination';destination.mkdir();(destination/'nested').mkdir()
            (destination/'nested/header.hh').write_text('stale')
            (destination/'nested/header.hh').chmod(0o444);(destination/'nested').chmod(0o555);destination.chmod(0o555)
            before=leaf.stat()
            value={'staged':{'root':str(source)},'prior':{'stagedReceipt':{'path':'retained'}}}
            try:
                native.N.copy_package(value,destination)
                self.assertEqual((destination/'nested/header.hh').read_text(),'accepted')
                self.assertEqual(leaf.stat(),before)
                self.assertEqual(destination.stat().st_mode & 0o777,0o555)
                self.assertEqual((destination/'nested').stat().st_mode & 0o777,0o555)
                outside=root/'outside';outside.mkdir();(outside/'header.hh').write_text('preserve')
                linked=root/'linked';linked.symlink_to(outside,target_is_directory=True)
                with self.assertRaises(ValueError):native.N.copy_package(value,linked)
                self.assertEqual((outside/'header.hh').read_text(),'preserve')
            finally:
                for base in (source,destination):
                    base.chmod(0o755)
                    for path in base.rglob('*'):
                        if path.is_dir():path.chmod(0o755)

    def test_refuses_nested_indirection_and_overlapping_destinations(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            root=Path(temp).resolve();source=root/'source';source.mkdir();(source/'nested').mkdir()
            (source/'nested/header.hh').write_text('accepted')
            outside=root/'outside';outside.mkdir();(outside/'header.hh').write_text('preserve')
            target=root/'target';target.mkdir();(target/'nested').symlink_to(outside,target_is_directory=True);target.chmod(0o555)
            source.chmod(0o555)
            value={'staged':{'root':str(source)},'prior':{'stagedReceipt':{'path':'retained'}}}
            try:
                with self.assertRaisesRegex(ValueError,'indirect'):native.N.copy_package(value,target)
                self.assertEqual((outside/'header.hh').read_text(),'preserve')
                self.assertEqual((source/'nested/header.hh').read_text(),'accepted')
                self.assertEqual(target.stat().st_mode & 0o777,0o555)
                with self.assertRaisesRegex(ValueError,'separate'):native.N.copy_package(value,source/'nested/new')
                with self.assertRaisesRegex(ValueError,'separate'):native.N.copy_package(value,root)
            finally:
                source.chmod(0o755);target.chmod(0o755)

class MachOKitTypedRenewalTests(unittest.TestCase):
    def test_typed_renewal_requires_prior_source_pins_and_unchanged_payload_metadata(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            root=Path(temp).resolve()/'materialized';root.mkdir();(root/'MATERIALIZATION.json').write_text('{}')
            audit=root.parent/'audit.json'
            audit.write_text(json.dumps({'scope':devices.SCOPE,'old_device':10,'new_device':11,
                'bindings':{},'snapshot_roots':[str(root)]}));audit.chmod(0o400)
            old={'path':str(machokit_renewal.receipt_path(root)),'fields':[10,100,33060,1,1609,101,102]}
            new={'path':old['path'],'fields':[11,200,33060,1,1609,201,202]}
            accepted={'MATERIALIZATION.json':{'fields':[10,92,33060,1,19,20,21],'link':None}}
            observed={'MATERIALIZATION.json':{'fields':[11,92,33060,1,19,20,21],'link':None}}
            root_fields=[11,91,16749,1,16,17,18]
            semantics={'schema_version':1,'root':str(root),'revision':'pinned','components':[{'name':'bound','revision':'exact'}]}
            digest=hashlib.sha256(b'[[".",11,91,16749,16,17,18],["MATERIALIZATION.json",11,92,33060,19,20,21]]').hexdigest()
            document={**semantics,'metadata_sha256':digest}
            def prove(doc=document,seen=observed,blobs=('a'*40,'a'*40),binding=new):
                return machokit_renewal.prove(root,old,binding,doc,semantics,accepted,seen,root_fields,blobs,'b'*64)
            with patch.dict(os.environ,{devices.ENV:str(audit)}):
                proof=prove()
                self.assertEqual(proof['old_binding'],old);self.assertEqual(proof['new_binding'],new)
                self.assertEqual(proof['document'],document)
                for key in semantics:
                    bad={**document,key:'wrong'}
                    with self.subTest(pin=key),self.assertRaisesRegex(ValueError,'schema or pinned'):prove(bad)
                with self.assertRaisesRegex(ValueError,'schema or pinned'):prove({**document,'unknown':True})
                with self.assertRaisesRegex(ValueError,'document digest'):prove({**document,'metadata_sha256':'0'*64})
                with self.assertRaisesRegex(ValueError,'semantic source'):prove(blobs=('a'*40,'c'*40))
                for field in range(1,7):
                    changed=observed['MATERIALIZATION.json']['fields'].copy();changed[field]+=1
                    with self.subTest(field=field),self.assertRaises(ValueError):
                        prove(seen={'MATERIALIZATION.json':{'fields':changed,'link':None}})
                with self.assertRaises(ValueError):prove(seen={'MATERIALIZATION.json':{'fields':[12,92,33060,1,19,20,21],'link':None}})
                with self.assertRaisesRegex(ValueError,'receipt path'):prove(binding={**new,'path':str(root.parent/'foreign')})
                with self.assertRaisesRegex(ValueError,'immutable'):prove(binding={**new,'fields':[11,200,33188,1,1609,201,202]})
                with self.assertRaises(ValueError):prove(seen={**observed,'../escape':observed['MATERIALIZATION.json']})

    def test_normal_lease_pass_admits_only_typed_renewal_once_and_retains_original_binding(self):
        import machokit_source_identity as domain
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            base=Path(temp).resolve();root=base/'MachOKit';root.mkdir()
            manifest=root/'MATERIALIZATION.json';manifest.write_text('{}');manifest.chmod(0o444);root.chmod(0o555)
            try:
                document=domain._admission_identity(root)
                receipt=machokit_renewal.receipt_path(root);receipt.write_text(json.dumps(document));receipt.chmod(0o444)
                old=native.N.record(receipt)
                accepted=cache.snapshot(root)
                replacement=base/'replacement.json';replacement.write_text(json.dumps(document));replacement.chmod(0o444);replacement.replace(receipt)
                sources=[]
                for name in ('SOURCE_FILES.json','SOURCE_PROVENANCE.json'):
                    path=base/name;path.write_text('{}');sources.append(native.N.record(path))
                value={'schema_version':1,'scope':cache.SCOPE,'consulted':[old],
                       'source_files_receipt':sources[0],'source_provenance_receipt':sources[1],
                       'snapshots':{str(root):accepted},'machokit_root':str(root),'machokit_manifest_sha256':'b'*64}
                proofpath=base/'renewal.json'
                with patch.object(cache,'snapshot',wraps=cache.snapshot) as lease:
                    cache.revalidate(value,machokit_renewal={'output':str(proofpath),'source_blobs':['a'*40,'a'*40]})
                    self.assertEqual(lease.call_count,1)
                self.assertEqual(value['consulted'],[old])
                proof=json.loads(proofpath.read_text())
                self.assertEqual(proof['old_binding'],old)
                self.assertEqual(proof['new_binding']['fields'],native.N.record(receipt)['fields'])
                cache.revalidate(value)
                another=base/'another.json';another.write_text(json.dumps(document));another.chmod(0o444);another.replace(receipt)
                with self.assertRaisesRegex(ValueError,'binding changed'):cache.revalidate(value)
            finally:root.chmod(0o755)

    def test_renewal_proof_itself_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            base=Path(temp).resolve();proof=base/'proof.json';proof.write_text('{}');proof.chmod(0o400)
            binding=native.N.record(proof)
            value={'schema_version':1,'scope':cache.SCOPE,'machokit_renewal_receipt':str(proof),
                   'machokit_renewal_binding':binding}
            replacement=base/'replacement';replacement.write_text('{}');replacement.chmod(0o400);replacement.replace(proof)
            with self.assertRaisesRegex(ValueError,'proof binding changed'):cache.revalidate(value)

    def test_metadata_digest_preserves_producer_path_component_order(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            root=Path(temp).resolve();(root/'pkg').mkdir()
            for name in ('MATERIALIZATION.json','pkg/file','pkg-extra'):(root/name).write_text('x')
            observed={
                'MATERIALIZATION.json':{'fields':[11,2,33060,1,1,3,4],'link':None},
                'pkg':{'fields':[11,5,16749,1,1,6,7],'link':None},
                'pkg/file':{'fields':[11,8,33060,1,1,9,10],'link':None},
                'pkg-extra':{'fields':[11,11,33060,1,1,12,13],'link':None}}
            records=b'[[".",11,1,16749,1,1,1],["MATERIALIZATION.json",11,2,33060,1,3,4],["pkg",11,5,16749,1,6,7],["pkg/file",11,8,33060,1,9,10],["pkg-extra",11,11,33060,1,12,13]]'
            semantics={'root':str(root),'schema_version':1}
            document={**semantics,'metadata_sha256':hashlib.sha256(records).hexdigest()}
            binding={'path':str(machokit_renewal.receipt_path(root)),'fields':[11,22,33060,1,100,1,1]}
            result=machokit_renewal.prove(root,binding,binding,document,semantics,observed,observed,
                [11,1,16749,1,1,1,1],['a'*40,'a'*40],'b'*64)
            self.assertEqual(result['document'],document)

    def test_foreign_owned_replacement_and_additive_proof_refuse_before_read(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            base=Path(temp).resolve();root=base/'MachOKit';root.mkdir()
            receipt=machokit_renewal.receipt_path(root);receipt.write_text('{}');receipt.chmod(0o444)
            ordinary=native.N.record(receipt);actual=receipt.lstat()
            foreign=SimpleNamespace(**{key:getattr(actual,key) for key in devices.FIELDS},st_uid=os.getuid()+1)
            value={'schema_version':1,'scope':cache.SCOPE,'machokit_root':str(root),'consulted':[ordinary]}
            with patch.object(Path,'lstat',return_value=foreign),patch.object(cache,'read',side_effect=AssertionError('must refuse before document read')):
                with self.assertRaisesRegex(ValueError,'owned receipt'):
                    cache.revalidate(value,machokit_renewal={'output':str(base/'proof'),'source_blobs':['a','a']})
                with self.assertRaisesRegex(ValueError,'owned receipt'):
                    cache.revalidate({**value,'machokit_renewal_receipt':str(receipt),'machokit_renewal_binding':ordinary})

class RetainedPatternAdapterInputTests(unittest.TestCase):
    def test_retained_adapter_root_reaches_config_environment_qualification_and_xcode(self):
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            base=Path(temp).resolve();root=base/'accepted build';root.mkdir()
            receipt=base/'accepted-receipt.md';receipt.write_text('Existing producer Release proof')
            env={};settings={};q={};command=[]
            with patch.object(release,'run',side_effect=AssertionError('must not run producer or verification')):
                release.apply_pattern_adapter(root,receipt,env,settings,q,command)
            self.assertEqual(env,{'MACSCOPE_PATTERN_ADAPTER_ROOT':str(root)})
            self.assertEqual(settings,{'MACSCOPE_PATTERN_ADAPTER_ROOT':str(root)})
            self.assertEqual(command,['MACSCOPE_PATTERN_ADAPTER_ROOT='+str(root)])
            self.assertEqual(q['retained_pattern_adapter']['root'],str(root))
            self.assertEqual(q['retained_pattern_adapter']['accepted_producer_receipt']['path'],str(receipt))
            indirect=base/'indirect';indirect.symlink_to(root,target_is_directory=True)
            with self.assertRaisesRegex(ValueError,'canonical'):release.apply_pattern_adapter(indirect,receipt,{}, {}, {}, [])
            unsafe=base/'bad$root';unsafe.mkdir()
            with self.assertRaisesRegex(ValueError,'represented'):release.apply_pattern_adapter(unsafe,receipt,{}, {}, {}, [])

class PatternQualificationSchemaTests(unittest.TestCase):
    def test_cache_only_typed_pattern_declaration_preserves_closed_schema_and_binding(self):
        from Scripts.reconstruction import validate_qualification_product_identity as validator
        with tempfile.TemporaryDirectory(dir=existing_work_root()) as temp:
            base=Path(temp).resolve();source=base/'source';(source/'MacScope').mkdir(parents=True)
            adapter=base/'adapter';adapter.mkdir();handoff=base/'accepted.md';handoff.write_text('Accepted producer receipt')
            config=source/'MacScope/DependencyRoots.local.xcconfig'
            config.write_text('MACSCOPE_PATTERN_ADAPTER_ROOT = '+str(adapter)+'\n')
            fields={key:None for key in validator.QUALIFICATION_V4_FIELDS}
            ordinary=fields.copy();cached={**fields,'cache_release_admission':'cache-inputs.json'}
            validator._validate_qualification_receipt_fields(ordinary,False,source)
            validator._validate_qualification_receipt_fields(cached,True,source)
            declaration={'root':str(adapter),'accepted_producer_receipt':native.N.record(handoff),
                'scope':'retained-pattern-adapter-input; producer evidence reused'}
            receipt={**cached,'retained_pattern_adapter':declaration}
            self.assertEqual(len(validator._validate_qualification_receipt_fields(receipt,True,source)),2)
            with self.assertRaisesRegex(validator.ProductIdentityError,'closed v4'):
                validator._validate_qualification_receipt_fields({**ordinary,'retained_pattern_adapter':declaration},False,source)
            with self.assertRaisesRegex(validator.ProductIdentityError,'closed v4'):
                validator._validate_qualification_receipt_fields({**receipt,'unknown':True},True,source)
            with self.assertRaisesRegex(validator.ProductIdentityError,'malformed'):
                validator._validate_qualification_receipt_fields({**receipt,'retained_pattern_adapter':{**declaration,'unknown':True}},True,source)
            config.write_text('MACSCOPE_PATTERN_ADAPTER_ROOT = '+str(base)+'\n')
            with self.assertRaisesRegex(validator.ProductIdentityError,'configuration'):
                validator._validate_qualification_receipt_fields(receipt,True,source)
            config.write_text('MACSCOPE_PATTERN_ADAPTER_ROOT = '+str(adapter)+'\n')
            indirect=base/'indirect';indirect.symlink_to(adapter,target_is_directory=True)
            with self.assertRaisesRegex(validator.ProductIdentityError,'canonical'):
                validator._validate_qualification_receipt_fields({**receipt,'retained_pattern_adapter':{**declaration,'root':str(indirect)}},True,source)
            handoff.write_text('Replaced producer receipt')
            with self.assertRaisesRegex(validator.ProductIdentityError,'binding changed'):
                validator._validate_qualification_receipt_fields(receipt,True,source)

if __name__=='__main__':unittest.main()
