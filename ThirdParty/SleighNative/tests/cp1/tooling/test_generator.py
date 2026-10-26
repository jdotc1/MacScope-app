"""Round-trip and repeat generation must preserve the shipped CP1 source bytes."""
import hashlib,pathlib,shutil,subprocess,sys,tempfile,unittest
REPO=pathlib.Path(sys.argv.pop(1)).resolve()
FIXTURE=pathlib.Path(sys.argv.pop(1)).resolve()
GENERATOR=pathlib.Path(__file__).with_name('generate_cp1.py')
class GeneratorTest(unittest.TestCase):
    def test_generation_is_byte_idempotent(self):
        source=REPO/'ThirdParty/SleighNative/AARCH64'
        with tempfile.TemporaryDirectory(prefix='cp1-generator-test-') as work:
            out=pathlib.Path(work)/'resources';shutil.copytree(source,out)
            expected={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir()}
            for run in range(2):
                subprocess.run([sys.executable,str(GENERATOR),'--fixture',str(FIXTURE),'--output',str(out)],check=True)
                observed={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir()}
                changed=[n for n in sorted(set(expected)|set(observed)) if expected.get(n)!=observed.get(n)]
                self.assertEqual(changed,[],f'round {run+1} altered the committed generated closure')
if __name__=='__main__':unittest.main()
