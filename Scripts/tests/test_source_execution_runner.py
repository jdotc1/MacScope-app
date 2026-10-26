#!/usr/bin/env python3
"""Controlled native confinement tests; opt-in local macOS, no Xcode project build."""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts' / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402
WORK_ROOT = macscope_work_root().resolve()
WORK = WORK_ROOT / 'source-runner-validation-20261006'
TOOLCHAIN = pathlib.Path('/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain')
SDK = pathlib.Path('/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk').resolve()

@unittest.skipUnless(os.environ.get('MACSCOPE_RUN_SOURCE_RUNNER_TESTS') == '1', 'Opt-in controlled native confinement fixtures')
class SourceRunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        WORK.mkdir(parents=True, exist_ok=True)
        cls.binary = WORK / 'tested-runner'
        subprocess.run([str(TOOLCHAIN / 'usr/bin/clang'), '-isysroot', str(SDK), '-std=c11',
                        '-Wall', '-Wextra', '-Werror', str(ROOT / 'MacScope/SourceExecutionRunner/main.c'),
                        '-o', str(cls.binary)], check=True, capture_output=True)

    def fixture(self, candidate, harness='int recovered(void); int main(void){return recovered();}'):
        root = pathlib.Path(tempfile.mkdtemp(dir=WORK)); root.chmod(0o700)
        (root / 'candidate.c').write_text(candidate)
        (root / 'harness.c').write_text(harness)
        return root

    def invoke(self, mode, root, **kwargs):
        args = [str(self.binary), mode, str(root)]
        if mode in ('compile', 'inspect'): args += [str(TOOLCHAIN / 'usr/bin/clang'), str(SDK), str(TOOLCHAIN)]
        environment = {**os.environ, **kwargs.pop("env", {}),
                       "MACSCOPE_WORK_ROOT": str(WORK_ROOT)}
        return subprocess.run(args, env=environment, capture_output=True, text=True, timeout=30, start_new_session=True,
                              input=kwargs.pop("input", "MACSCOPE_SOURCE_EXECUTION_ACK_V1\n"), **kwargs)

    def test_requires_explicit_launch_acknowledgement(self):
        root = self.fixture('int recovered(void){return 0;}')
        result = self.invoke('compile', root, input='incorrect\n')
        self.assertEqual(result.returncode, 125)
        self.assertIn('acknowledgement missing or invalid', result.stderr)
        self.assertFalse((root / 'output/candidate').exists())
        other = self.fixture('int recovered(void){return 0;}')
        self.assertEqual(self.invoke('compile', other, input='').returncode, 125)

    def test_inspection_is_complete_ast_with_same_profile_before_compile(self):
        root = self.fixture('#include <stdint.h>\nuint32_t reconstructed(uint32_t x){return x == UINT32_MAX ? x : x+1;}')
        result = self.invoke('inspect', root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        import json
        ast = json.loads((root/'inspection/candidate.ast.json').read_bytes())
        self.assertEqual(ast['kind'], 'TranslationUnitDecl')
        self.assertLessEqual((root/'inspection/candidate.ast.json').stat().st_size, 1048576)
        self.assertFalse((root/'output').exists())

    def test_compile_and_actual_behavior(self):
        root = self.fixture('int recovered(void){return 0;}')
        self.assertEqual(self.invoke('compile', root).returncode, 0)
        self.assertEqual(self.invoke('behavior', root).returncode, 0)

    def test_behavior_denies_user_files_network_fork_spawn_and_writes(self):
        secret = WORK / 'private-denial-canary'; secret.write_text('CANARY')
        root = self.fixture(r'''
#include <sys/socket.h>
#include <sys/resource.h>
#include <netinet/in.h>
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
extern char **environ;
int recovered(void) {
    if (open("SECRET_PATH", O_RDONLY) != -1 || errno != EPERM) return 1;
    if (open("WRITE_PATH", O_WRONLY|O_CREAT, 0600) != -1 || errno != EPERM) return 2;
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd>=0) { struct sockaddr_in a={0}; a.sin_family=AF_INET; a.sin_port=htons(9); a.sin_addr.s_addr=htonl(0x7f000001);
        if (connect(fd,(struct sockaddr*)&a,sizeof a)!=-1 || errno!=EPERM) return 3; close(fd); }
    else if (errno!=EPERM) return 4;
    if (fork()!=-1 || errno!=EPERM) return 5;
    pid_t p; char *args[]={"true",0};
    if (posix_spawn(&p,"/usr/bin/true",0,0,args,environ)!=EPERM) return 6;
    if (getenv("SOURCE_RUNNER_SECRET") || strcmp(getenv("HOME"),"/nonexistent")) return 7;
    struct rlimit r;
    if (getrlimit(RLIMIT_CPU,&r) || r.rlim_cur!=10 || r.rlim_max!=10) return 8;
    if (getrlimit(RLIMIT_NOFILE,&r) || r.rlim_cur!=64 || r.rlim_max!=64) return 9;
    if (getrlimit(RLIMIT_FSIZE,&r) || r.rlim_cur!=1048576) return 10;
    if (getrlimit(RLIMIT_CORE,&r) || r.rlim_cur!=0) return 11;
    if (getrlimit(RLIMIT_STACK,&r) || r.rlim_cur!=8388608) return 12;
    int opened=0;
    while (open("/dev/null",O_RDONLY)>=0) { if (++opened>64) return 13; }
    if (errno!=EMFILE || opened>61) return 14;
    return 0;
}'''.replace('SECRET_PATH', str(secret)).replace('WRITE_PATH', str(WORK/'forbidden-write')))
        self.assertEqual(self.invoke('compile', root).returncode, 0)
        result = self.invoke('behavior', root, env={**os.environ, 'SOURCE_RUNNER_SECRET': 'must-not-inherit'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((WORK/'forbidden-write').exists())

    def test_compiler_cannot_include_user_file(self):
        secret = WORK / 'include-denial-canary.h'; secret.write_text('int recovered(void){return 0;}')
        root = self.fixture('#include "'+str(secret)+'"\n')
        result = self.invoke('compile', root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Operation not permitted', result.stderr)

    def test_cpu_limit_terminates_busy_candidate_and_oversized_binary_is_rejected(self):
        root = self.fixture('int recovered(void){volatile unsigned x=0; for(;;) ++x;}')
        self.assertEqual(self.invoke('compile', root).returncode, 0)
        result = self.invoke('behavior', root)
        self.assertLess(result.returncode, 0)
        with (root/'output/candidate').open('ab') as stream:
            stream.truncate(1048577)
        self.assertEqual(self.invoke('behavior', root).returncode, 125)

    def test_file_size_limit_stops_large_compiler_product(self):
        root = self.fixture('const unsigned char blob[2097152]={1}; int recovered(void){return blob[0]-1;}')
        result = self.invoke('compile', root)
        self.assertNotEqual(result.returncode, 0)
        for output in (root/'output').iterdir():
            if output.is_file(): self.assertLessEqual(output.stat().st_size, 1048576)

    def test_rejects_symlink_source_and_preexisting_output(self):
        root = self.fixture('int recovered(void){return 0;}')
        (root/'output').mkdir()
        self.assertEqual(self.invoke('compile', root).returncode, 125)
        other = self.fixture('int recovered(void){return 0;}')
        (other/'candidate.c').unlink(); (other/'candidate.c').symlink_to(root/'candidate.c')
        self.assertEqual(self.invoke('compile', other).returncode, 125)

class SourceRunnerEnvironmentTests(unittest.TestCase):
    def test_invoke_exports_resolved_root_without_losing_environment(self):
        runner = SourceRunnerTests()
        runner.binary = pathlib.Path("/unused/runner")
        with patch.dict(os.environ, {"INHERITED_CANARY": "retained"}, clear=True):
            with patch.object(subprocess, "run") as run:
                runner.invoke("behavior", pathlib.Path("/unused/stage"))
                self.assertEqual(run.call_args.kwargs["env"],
                                 {"INHERITED_CANARY": "retained",
                                  "MACSCOPE_WORK_ROOT": str(WORK_ROOT)})
                runner.invoke("behavior", pathlib.Path("/unused/stage"),
                              env={"SOURCE_RUNNER_SECRET": "must-not-inherit"})
                self.assertEqual(run.call_args.kwargs["env"],
                                 {"INHERITED_CANARY": "retained",
                                  "SOURCE_RUNNER_SECRET": "must-not-inherit",
                                  "MACSCOPE_WORK_ROOT": str(WORK_ROOT)})


if __name__ == '__main__': unittest.main()
