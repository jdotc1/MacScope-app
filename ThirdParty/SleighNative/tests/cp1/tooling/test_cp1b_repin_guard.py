"""The additive reviewed series remains closed; no package bypass is used."""
import importlib.util,json,pathlib,shutil,sys,tempfile,unittest
ROOT=pathlib.Path(sys.argv.pop(1)).resolve();SPEC=importlib.util.spec_from_file_location('repin',ROOT/'ThirdParty/SleighNative/tests/cp1/tooling/rederive_pins.py');M=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(M)
class TestReviewedSeries(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name)/'repo';self.component=self.root/'ThirdParty/SleighNative';self.component.mkdir(parents=True)
  src=ROOT/'ThirdParty/SleighNative'
  for name in ['AARCH64','patches'] :shutil.copytree(src/name,self.component/name)
  for name in ['MATERIALIZATION.json','PATCHED_RESOURCES.json','CP1_BASELINE.json']:shutil.copyfile(src/name,self.component/name)
  self.patches=self.component/'patches/aarch64';self.resources=self.component/'AARCH64'
 def tearDown(self):self.temp.cleanup()
 def derive(self):return M.derive(self.root,self.resources)
 def test_reviewed_series_reaches_required_materialization_guard(self):
  with self.assertRaisesRegex(ValueError,'materialized|absent|missing'):self.derive()
 def test_missing_patch_rejected(self):
  next(self.patches.glob('0017-*')).unlink()
  with self.assertRaisesRegex(ValueError,'patch set must be exactly reviewed'):self.derive()
 def test_missing_secondpass_patch_rejected(self):
  next(self.patches.glob('0019-*')).unlink()
  with self.assertRaisesRegex(ValueError,'patch set must be exactly reviewed'):self.derive()
 def test_duplicate_secondpass_patch_rejected(self):
  (self.patches/'0019-duplicate.patch').write_text('')
  with self.assertRaisesRegex(ValueError,'patch set must be exactly reviewed'):self.derive()
 def test_unexpected_patch_rejected(self):
  (self.patches/'0020-unreviewed.patch').write_text('')
  with self.assertRaisesRegex(ValueError,'patch set must be exactly reviewed'):self.derive()
 def test_unexpected_nonpatch_member_rejected(self):
  (self.patches/'notes.txt').write_text('')
  with self.assertRaisesRegex(ValueError,'patch set must be exactly reviewed'):self.derive()
 def test_duplicate_reviewed_prefix_rejected(self):
  (self.patches/'0018-duplicate.patch').write_text('')
  with self.assertRaisesRegex(ValueError,'patch set must be exactly reviewed'):self.derive()
if __name__=='__main__':unittest.main()
