#!/usr/bin/env python3
"""Drive an installed MacScope via native Accessibility, preserving every attempt.

No product hooks, private store mutations, or forced process termination are used.
A failed action writes a failed receipt and leaves the live app available for diagnosis.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402


# AppleScript receives all user content as argv, never as executable source.
AX_SCRIPT = r'''
on run argv
    set pidText to item 1 of argv
    set operation to item 2 of argv
    tell application "System Events"
        set targetProcess to first application process whose unix id is (pidText as integer)
        tell targetProcess
            set frontmost to true
            if operation is "key" then
                set taskKeyModifiers to {}
                if item 4 of argv contains "command" then set end of taskKeyModifiers to command down
                if item 4 of argv contains "control" then set end of taskKeyModifiers to control down
                if item 4 of argv contains "option" then set end of taskKeyModifiers to option down
                if item 4 of argv contains "shift" then set end of taskKeyModifiers to shift down
                keystroke (item 3 of argv) using taskKeyModifiers
            else if operation is "return" then
                key code 36
            else if operation is "escape" then
                key code 53
            else if operation is "text" then
                keystroke (item 3 of argv)
            else if operation is "menu" then
                set menuNames to items 3 thru -1 of argv
                set currentItem to menu bar item (item 1 of menuNames) of menu bar 1
                click currentItem
                repeat with nameIndex from 2 to count of menuNames
                    set currentItem to menu item (item nameIndex of menuNames) of menu 1 of currentItem
                    if nameIndex < (count of menuNames) then
                        perform action "AXShowMenu" of currentItem
                    else
                        click currentItem
                    end if
                end repeat
            else if operation is "document" then
                set expectedTitle to item 3 of argv
                repeat with currentWindow in windows
                    set observedTitle to name of currentWindow as text
                    if observedTitle is expectedTitle or observedTitle starts with (expectedTitle & " —") then
                        perform action "AXRaise" of currentWindow
                        return "true"
                    end if
                end repeat
                error "Expected document window did not open: " & expectedTitle
            else if operation is "no-alert" then
                repeat with currentWindow in windows
                    if (count of sheets of currentWindow) > 0 then error "Native modal sheet remains open"
                    if subrole of currentWindow is "AXDialog" then error "Native dialog remains open"
                end repeat
                return "true"
            else
                error "Unsupported AppleScript native operation"
            end if
        end tell
    end tell
end run
'''


def run(argv: list[str], timeout: float = 30) -> str:
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{Path(argv[0]).name} failed ({result.returncode}): {result.stderr.strip()}')
    return result.stdout.strip()


class GUIAcceptanceLease:
    """Share the qualifier's machine-wide lock for the complete GUI scenario."""

    def __init__(self, work_root: Path, *, lock: Path | None = None):
        self.work_root = work_root.resolve()
        self.lock = lock or macscope_work_root() / '.macscope-heavy-gate.lock'
        self.helper = Path(__file__).resolve().parents[1] / 'qualification/heavy_gate_lock.py'
        self.fd = None
        self.acquired = False

    def acquire(self):
        if self.fd is not None:
            raise RuntimeError('GUI acceptance lease is already open')
        self.lock.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.lock, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            subprocess.run([
                sys.executable, '-B', str(self.helper), 'acquire',
                '--fd', str(self.fd), '--lock', str(self.lock), '--pid', str(os.getpid()),
                '--work-root', str(self.work_root), '--run-root', str(self.work_root),
                '--integration-ref', 'installed-native-acceptance', '--mode', 'installed-gui',
            ], pass_fds=(self.fd,), check=True)
            self.acquired = True
        except BaseException:
            self.release()
            raise

    def release(self):
        if self.fd is None:
            return
        try:
            if self.acquired:
                subprocess.run([
                    sys.executable, '-B', str(self.helper), 'release',
                    '--lock', str(self.lock), '--pid', str(os.getpid()),
                ], check=True)
        finally:
            os.close(self.fd)
            self.fd = None
            self.acquired = False

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *unused):
        self.release()


def hash_tree(root: Path) -> dict[str, str]:
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'Package contains symlink: {path}')
        if path.is_file():
            result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not result:
        raise ValueError('Empty workspace package')
    return result


def semantic_tree(root: Path) -> dict:
    """JSON objects compare independent of key ordering; all non-JSON bytes stay exact."""
    result = {}
    for relative, digest in hash_tree(root).items():
        path = root / relative
        if path.suffix == '.json':
            result[relative] = json.loads(path.read_text())
        else:
            result[relative] = {'sha256': digest}
    return result


def wait_until(probe, timeout: float = 30):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except (subprocess.SubprocessError, ValueError, OSError, RuntimeError) as error:
            last_error = error
        time.sleep(.25)
    raise TimeoutError(f'Native state did not settle: {last_error}')


class NativeAccessibility:
    """Bounded native AX traversal, avoiding per-element Apple Event round trips."""
    def __init__(self, pid, document_title=None):
        self.document_title = document_title
        self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.ax = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
        ptr = ctypes.c_void_p
        self.cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
        self.cf.CFStringCreateWithCString.restype = ptr
        self.cf.CFStringGetCString.argtypes = [ptr, ptr, ctypes.c_long, ctypes.c_uint32]
        self.cf.CFStringGetCString.restype = ctypes.c_bool
        self.cf.CFGetTypeID.argtypes = [ptr]
        self.cf.CFGetTypeID.restype = ctypes.c_ulong
        self.cf.CFStringGetTypeID.restype = ctypes.c_ulong
        self.cf.CFArrayGetTypeID.restype = ctypes.c_ulong
        self.cf.CFArrayGetCount.argtypes = [ptr]
        self.cf.CFArrayGetCount.restype = ctypes.c_long
        self.cf.CFArrayGetValueAtIndex.argtypes = [ptr, ctypes.c_long]
        self.cf.CFArrayGetValueAtIndex.restype = ptr
        self.cf.CFRetain.argtypes = [ptr]
        self.cf.CFRetain.restype = ptr
        self.cf.CFRelease.argtypes = [ptr]
        self.ax.AXUIElementCreateApplication.argtypes = [ctypes.c_int]
        self.ax.AXUIElementCreateApplication.restype = ptr
        self.ax.AXUIElementCopyAttributeValue.argtypes = [ptr, ptr, ctypes.POINTER(ptr)]
        self.ax.AXUIElementCopyAttributeValue.restype = ctypes.c_int
        self.ax.AXUIElementSetAttributeValue.argtypes = [ptr, ptr, ptr]
        self.ax.AXUIElementSetAttributeValue.restype = ctypes.c_int
        self.ax.AXUIElementPerformAction.argtypes = [ptr, ptr]
        self.ax.AXUIElementPerformAction.restype = ctypes.c_int
        self.app = self.ax.AXUIElementCreateApplication(pid)
        self.true_value = ptr.in_dll(self.cf, 'kCFBooleanTrue')

    def close(self):
        self.cf.CFRelease(self.app)

    def string(self, value):
        return self.cf.CFStringCreateWithCString(None, value.encode(), 0x08000100)

    def attribute(self, element, key):
        key_ref = self.string(key)
        value = ctypes.c_void_p()
        try:
            code = self.ax.AXUIElementCopyAttributeValue(element, key_ref, ctypes.byref(value))
            return value.value if code == 0 else None
        finally:
            self.cf.CFRelease(key_ref)

    def text(self, element, key):
        value = self.attribute(element, key)
        if not value:
            return None
        try:
            if self.cf.CFGetTypeID(value) != self.cf.CFStringGetTypeID():
                return None
            buffer = ctypes.create_string_buffer(65536)
            return buffer.value.decode() if self.cf.CFStringGetCString(value, buffer, len(buffer), 0x08000100) else None
        finally:
            self.cf.CFRelease(value)

    def find(self, selector):
        pending = [self.cf.CFRetain(self.app)]
        held = []
        matches = []
        deadline = time.monotonic() + 10
        try:
            while pending:
                if len(held) > 20000 or time.monotonic() > deadline:
                    raise TimeoutError('Native AX traversal exceeded bound')
                element = pending.pop()
                held.append(element)
                if self.document_title and self.text(element, 'AXRole') == 'AXWindow':
                    title = self.text(element, 'AXTitle') or ''
                    if title != self.document_title and not title.startswith(self.document_title + ' —'):
                        continue
                if any(self.text(element, key) == selector for key in
                       ('AXIdentifier', 'AXTitle', 'AXDescription', 'AXPlaceholderValue')):
                    matches.append(element)
                children = self.attribute(element, 'AXChildren')
                if children:
                    try:
                        if self.cf.CFGetTypeID(children) == self.cf.CFArrayGetTypeID():
                            for index in range(self.cf.CFArrayGetCount(children)):
                                pending.append(self.cf.CFRetain(self.cf.CFArrayGetValueAtIndex(children, index)))
                    finally:
                        self.cf.CFRelease(children)
            if len(matches) != 1:
                raise ValueError(f'AX selector missing or ambiguous: {selector!r} ({len(matches)})')
            return self.cf.CFRetain(matches[0])
        finally:
            for element in held + pending:
                self.cf.CFRelease(element)

    def perform(self, operation, selector, value=None):
        element = self.find(selector)
        key_ref = value_ref = None
        try:
            if operation in ('press', 'popup'):
                key_ref = self.string('AXPress')
                code = self.ax.AXUIElementPerformAction(element, key_ref)
            elif operation in ('set', 'focus'):
                key_ref = self.string('AXFocused' if operation == 'focus' else 'AXValue')
                value_ref = self.string(value) if operation == 'set' else self.cf.CFRetain(self.true_value)
                code = self.ax.AXUIElementSetAttributeValue(element, key_ref, value_ref)
            elif operation == 'value':
                return self.text(element, 'AXValue')
            elif operation == 'exists':
                return True
            else:
                raise ValueError(f'Unsupported AX operation {operation}')
            if code != 0:
                raise RuntimeError(f'Native AX {operation} failed ({code}) for {selector!r}')
            return True
        finally:
            self.cf.CFRelease(element)
            if key_ref:
                self.cf.CFRelease(key_ref)
            if value_ref:
                self.cf.CFRelease(value_ref)


class NativeApp:
    def __init__(self, bundle: Path, script: Path):
        self.bundle = bundle
        self.script = script
        self.executable = bundle / 'Contents/MacOS/MacScope'
        self.pid = None
        self.document_title = None

    def pids(self):
        # Bind identity to the executable path, not the display name or bundle identifier.
        output = run(['/bin/ps', '-axo', 'pid=,comm='])
        return [int(line.strip().split(None, 1)[0]) for line in output.splitlines()
                if len(line.strip().split(None, 1)) == 2
                and line.strip().split(None, 1)[1] == str(self.executable)]

    def launch(self):
        if self.pids():
            raise ValueError('Candidate is already running; finish the existing native session first')
        run(['/usr/bin/open', '-n', str(self.bundle)])
        self.pid = wait_until(lambda: self.pids())[0]
        wait_until(lambda: self.ax('key', '', ''))
        return self.pid

    def ax(self, operation, *values):
        if self.pids() != [self.pid]:
            raise ValueError('Native candidate PID disappeared or another exact candidate is running')
        if operation in ('key', 'text', 'return', 'escape', 'menu'):
            activation = 'on run argv\n tell application (item 1 of argv) to activate\nend run'
            run(['/usr/bin/osascript', '-e', activation, str(self.bundle)])
        if operation in ('press', 'focus', 'set', 'exists', 'value', 'popup'):
            backend = NativeAccessibility(self.pid, self.document_title)
            try:
                result = backend.perform(operation, *values[:1], value=values[1] if len(values) > 1 else None)
                if operation == 'popup':
                    # AppKit hosts the opened menu outside its document window. The opening
                    # control was document-scoped; resolve its unique item in this same app PID.
                    backend.document_title = None
                    wait_until(lambda: backend.perform('press', values[1]))
                return result
            finally:
                backend.close()
        output = run(['/usr/bin/osascript', str(self.script), str(self.pid), operation, *values])
        return output or True

    def menu(self, *names):
        return self.ax('menu', *names)

    def open_workspace(self, workspace: Path):
        # LaunchServices uses the app's ordinary native open-document route.
        # Reopening is still driven through the native Open Recent menu.
        self.document_title = workspace.stem
        run(['/usr/bin/open', '-a', str(self.bundle), str(workspace)])
        wait_until(lambda: self.ax('document', workspace.stem))
        wait_until(lambda: self.ax('exists', 'workspace.root'))
        wait_until(lambda: self.ax('no-alert'))

    def save(self):
        self.ax('key', 's', 'command')
        wait_until(lambda: self.ax('no-alert'))

    def quit(self):
        self.ax('key', 'q', 'command')
        old_pid = self.pid
        wait_until(lambda: old_pid not in self.pids())
        self.pid = None
        return old_pid


def stable_package(workspace: Path, minimum_seconds: float = 1):
    previous = hash_tree(workspace)
    stable_since = time.monotonic()
    def probe():
        nonlocal previous, stable_since
        current = hash_tree(workspace)
        if current != previous:
            previous, stable_since = current, time.monotonic()
        return current if time.monotonic() - stable_since >= minimum_seconds else None
    return wait_until(probe)


def rendered_output_lines(transcript: str):
    # The native Copy Full Transcript format prefixes each output event and uses
    # a visible newline glyph. Join event fragments before asserting output lines.
    output = ''.join(line[5:] for line in transcript.splitlines() if line.startswith('out: '))
    return output.replace('↵', '\n').splitlines()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/MacScope.app'))
    parser.add_argument('--source-workspace', type=Path)
    parser.add_argument('--scenario', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--hold-gui-lock', action='store_true',
                        help='Hold the shared lock for Computer Use; send release or close stdin to finish')
    parser.add_argument('--resume-pid', type=int)
    parser.add_argument('--opened-workspace', type=Path)
    args = parser.parse_args()
    if not args.hold_gui_lock and (args.source_workspace is None or args.scenario is None):
        parser.error('--source-workspace and --scenario are required for workspace acceptance')
    # A new output root is a recovery boundary: never overwrite an earlier attempt.
    args.output.mkdir(parents=True, exist_ok=False)
    if args.hold_gui_lock:
        with GUIAcceptanceLease(args.output):
            print('GUI_ACCEPTANCE_LOCK_ACQUIRED', flush=True)
            for line in sys.stdin:
                if line.strip() == 'release':
                    break
        print('GUI_ACCEPTANCE_LOCK_RELEASED', flush=True)
        return
    receipt = {'schema_version': 1, 'status': 'failed', 'stages': [], 'driver': 'native-accessibility'}
    started = time.monotonic()
    lease = GUIAcceptanceLease(args.output)
    try:
        lease.acquire()
        receipt['heavy_gate_lock'] = str(lease.lock)
        scenario = json.loads(args.scenario.read_text())
        source = args.source_workspace.resolve(strict=True)
        app_path = args.app.resolve(strict=True)
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app_path)])
        provenance = json.loads((app_path / 'Contents/Resources/MacScopeBuildProvenance.json').read_text())
        if provenance.get('configuration') != 'Release' or not provenance.get('qualification_eligible'):
            raise ValueError('Installed candidate must be qualification-eligible Release')
        receipt['provenance'] = provenance
        receipt['executable_sha256'] = hashlib.sha256((app_path / 'Contents/MacOS/MacScope').read_bytes()).hexdigest()
        receipt['source_hashes_before'] = hash_tree(source)
        if (args.resume_pid is None) != (args.opened_workspace is None):
            raise ValueError('--resume-pid and --opened-workspace must be supplied together')
        if args.opened_workspace is not None:
            workspace = args.opened_workspace.resolve(strict=True)
            if workspace == source:
                raise ValueError('Cannot mutate protected source workspace')
            receipt['resumed_existing_document'] = True
            receipt['workspace_hashes_before'] = hash_tree(workspace)
        else:
            workspace = args.output.resolve() / 'Acceptance Workspace.mscope'
            shutil.copytree(source, workspace)
        receipt['workspace'] = str(workspace)
        script = args.output.resolve() / 'NativeDriver.applescript'
        script.write_text(AX_SCRIPT)
        app = NativeApp(app_path, script)
        if args.resume_pid is not None:
            if app.pids() != [args.resume_pid]:
                raise ValueError('Resumed PID is not the sole exact installed candidate')
            app.pid = args.resume_pid
            app.document_title = workspace.stem
            wait_until(lambda: app.ax('document', workspace.stem))
            wait_until(lambda: app.ax('exists', 'workspace.root'))
            receipt['first_pid'] = app.pid
        else:
            receipt['first_pid'] = app.launch()
            app.open_workspace(workspace)
        receipt['stages'].append({'stage': 'native-open', 'passed': True})
        print('Native workspace opened', flush=True)
        for action in scenario.get('actions', []):
            operation = action['operation']
            if operation == 'menu':
                app.menu(*action['path'])
            elif operation == 'wait':
                selector = action['selector']
                expected = action.get('equals')
                wait_until(lambda: app.ax('value', selector) == expected if expected is not None
                           else app.ax('exists', selector), action.get('timeout', 30))
            elif operation == 'wait_transcript':
                def transcript_ready():
                    app.ax('popup', 'Transcript', 'Copy Full Transcript')
                    transcript = run(['/usr/bin/pbpaste'])
                    lines = rendered_output_lines(transcript)
                    return transcript if all(lines.count(line) >= count for line, count
                                             in action.get('output_counts', {}).items()) else None
                wait_until(transcript_ready, action.get('timeout', 30))
            elif operation == 'copy_transcript':
                app.ax('popup', 'Transcript', 'Copy Full Transcript')
                transcript = run(['/usr/bin/pbpaste'])
                (args.output / action.get('file', 'TRANSCRIPT.txt')).write_text(transcript)
                for line, expected_count in action.get('line_counts', {}).items():
                    count = transcript.splitlines().count(line)
                    if count != expected_count:
                        raise ValueError(f'Transcript line {line!r}: {count}, expected {expected_count}')
                for line, expected_count in action.get('output_counts', {}).items():
                    count = rendered_output_lines(transcript).count(line)
                    if count != expected_count:
                        raise ValueError(f'Transcript output {line!r}: {count}, expected {expected_count}')
            elif operation == 'wait_process_alive':
                pid_file = args.output.resolve() / action['pid_file']
                pid = int(wait_until(lambda: pid_file.read_text().strip() if pid_file.exists() else None))
                def alive():
                    output = run(['/bin/ps', '-axo', 'pid=,pgid=,comm='])
                    for line in output.splitlines():
                        fields = line.strip().split(None, 2)
                        if len(fields) == 3 and fields[0] == str(pid):
                            if action.get('command') and fields[2] != action['command']:
                                return None
                            return {'pid': pid, 'pgid': int(fields[1]), 'command': fields[2]}
                    return None
                observation = wait_until(alive, action.get('timeout', 30))
                if action.get('group_leader') and observation['pid'] != observation['pgid']:
                    raise ValueError('Acceptance foreground child did not own its process group')
                receipt.setdefault('process_oracles', {})[action['pid_file']] = observation
            elif operation == 'wait_process_group_exit':
                observation = receipt['process_oracles'][action['pid_file']]
                def group_absent():
                    output = run(['/bin/ps', '-axo', 'pgid='])
                    return str(observation['pgid']) not in output.split()
                wait_until(group_absent, action.get('timeout', 30))
            elif operation == 'wait_process_exit':
                pid_file = args.output.resolve() / action['pid_file']
                pid = int(wait_until(lambda: pid_file.read_text().strip() if pid_file.exists() else None))
                if pid <= 1 or pid == app.pid:
                    raise ValueError('Invalid acceptance child PID')
                def exited():
                    observed = run(['/bin/ps', '-axo', 'pid=,pgid=,comm='])
                    return not any(line.split() and line.split()[0] == str(pid)
                                   for line in observed.splitlines())
                wait_until(exited, action.get('timeout', 30))
            elif operation in ('press', 'popup', 'focus', 'set', 'text', 'key', 'return', 'escape'):

                arguments = [value.replace('{output}', str(args.output.resolve()))
                             for value in action.get('arguments', [])]
                app.ax(operation, *arguments)
            else:
                raise ValueError(f'Unsupported native action {operation}')
            receipt['stages'].append({'stage': 'action', 'action': action, 'passed': True})
            print(json.dumps({'completed_action': action}), flush=True)
        app.save()
        receipt['stages'].append({'stage': 'save-command-no-modal-error', 'passed': True})
        receipt['saved_hashes'] = stable_package(workspace)
        # Optional semantic expectations are required for scenario-specific delivery claims.
        saved_semantic = semantic_tree(workspace)
        for expectation in scenario.get('package_expectations', []):
            value = saved_semantic[expectation['file']]
            path = expectation.get('path', [])
            if expectation.get('absent'):
                for key in path[:-1]:
                    value = value[key]
                if not path or path[-1] in value:
                    raise ValueError(f'Expected package field to be absent: {expectation}')
                continue
            for key in path:
                value = value[key]
            if value != expectation['equals']:
                raise ValueError(f'Package expectation failed: {expectation}')
        receipt['stages'].append({'stage': 'native-save', 'passed': True})
        receipt['quit_pid'] = app.quit()
        receipt['quit_hashes'] = hash_tree(workspace)
        quit_semantic = semantic_tree(workspace)
        shutil.copytree(workspace, args.output / 'Before Reopen.mscope')
        receipt['second_pid'] = app.launch()
        if receipt['second_pid'] == receipt['first_pid']:
            raise ValueError('Relaunch did not establish a new process')
        app.menu('File', 'Open Recent', workspace.stem)
        wait_until(lambda: app.ax('document', workspace.stem))
        wait_until(lambda: app.ax('exists', 'workspace.root'))
        wait_until(lambda: app.ax('no-alert'))
        for selector in scenario.get('reopened_selectors', []):
            wait_until(lambda: app.ax('exists', selector))
        if scenario.get('reopened_output_counts'):
            app.ax('popup', 'Transcript', 'Copy Full Transcript')
            reopened_transcript = run(['/usr/bin/pbpaste'])
            (args.output / 'REOPENED_TRANSCRIPT.txt').write_text(reopened_transcript)
            for line, expected_count in scenario['reopened_output_counts'].items():
                if rendered_output_lines(reopened_transcript).count(line) != expected_count:
                    raise ValueError(f'Reopened transcript output failed: {line!r}')
        receipt['reopened_hashes'] = stable_package(workspace)
        receipt['reopened_semantic_equal'] = semantic_tree(workspace) == quit_semantic
        if not receipt['reopened_semantic_equal']:
            raise ValueError('Package contents changed after native Open Recent')
        receipt['source_hashes_after'] = hash_tree(source)
        if receipt['source_hashes_before'] != receipt['source_hashes_after']:
            raise ValueError('Protected source workspace changed')
        receipt['stages'].append({'stage': 'native-quit-relaunch-open-recent', 'passed': True})
        receipt['status'] = 'passed'
        receipt['scope'] = scenario.get('name', 'workspace-roundtrip')
        receipt['scenario_specific_assertions'] = len(scenario.get('package_expectations', []))
    except Exception as error:
        receipt['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        try:
            receipt['wall_seconds'] = round(time.monotonic() - started, 3)
            (args.output / 'NATIVE_ACCEPTANCE.json').write_text(json.dumps(receipt, indent=2) + '\n')
        finally:
            lease.release()


if __name__ == '__main__':
    main()
