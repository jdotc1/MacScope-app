"""Native-only end-to-end tests for the macscope Python client.

These drive a real headless ``MacScope --mcp <fixture>`` subprocess (no GUI) against a
repository-controlled Mach-O: ``fixtures/native_client_fixture.c`` is compiled at session
setup with ``xcrun clang -arch arm64`` into a temporary directory, and every expected name
and address is read back from that image with ``nm``.

The MacScope executable is bound to a qualification receipt (see ``native_binding.py``):
set ``MACSCOPE_NATIVE_TEST_RECEIPT`` to ``<run-root>/candidate-artifacts/
NativeLivePreparation.receipt.json``, or set ``MACSCOPE_NATIVE_TEST_EXECUTABLE`` plus
``MACSCOPE_NATIVE_TEST_EXECUTABLE_SHA256``. The executable's SHA-256 must equal the recorded
digest. Without a binding the module skips with that reason; an invalid binding fails.

This module needs pytest and is excluded by name from the portable runner
(``Scripts/ci/run_python_client_tests.py``).
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, NamedTuple

import pytest

TESTS_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIRECTORY.parent))
sys.path.insert(0, str(TESTS_DIRECTORY))
import macscope  # noqa: E402
import native_binding  # noqa: E402

FIXTURE_SOURCE = TESTS_DIRECTORY / "fixtures" / "native_client_fixture.c"
FIXTURE_FUNCTIONS = ("_macscope_fixture_add", "_macscope_fixture_twice", "_main")
FIXTURE_ZERO_FILL_SYMBOL = "_macscope_fixture_zero"
FIXTURE_IMPORT = "_getenv"
HEADER_SYMBOL = "__mh_execute_header"
RENAMED = "macscope_fixture_renamed_add"


class FixtureImage(NamedTuple):
    path: str
    header: int
    functions: Dict[str, int]
    zero_fill: int


@pytest.fixture(scope="session")
def bound_executable() -> str:
    try:
        binding = native_binding.resolve_binding()
    except native_binding.BindingError as error:
        pytest.fail(f"invalid native MacScope binding: {error}", pytrace=False)
    if binding is None:
        pytest.skip(native_binding.UNBOUND_REASON)
    return binding.executable


def _nm_symbols(path: str) -> Dict[str, "tuple[str, int]"]:
    output = subprocess.run(
        ["/usr/bin/xcrun", "nm", "-n", path],
        check=True,
        stdout=subprocess.PIPE,
        universal_newlines=True,
    ).stdout
    symbols = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3:
            address, kind, name = fields
            symbols[name] = (kind, int(address, 16))
    return symbols


@pytest.fixture(scope="session")
def fixture_image(bound_executable: str, tmp_path_factory) -> FixtureImage:
    if sys.platform != "darwin" or not os.path.exists("/usr/bin/xcrun"):
        pytest.skip("compiling the Mach-O fixture needs macOS with /usr/bin/xcrun")
    output = tmp_path_factory.mktemp("native-fixture") / "native_client_fixture"
    subprocess.run(
        ["/usr/bin/xcrun", "clang", "-arch", "arm64", "-O1", "-o", str(output), str(FIXTURE_SOURCE)],
        check=True,
    )
    symbols = _nm_symbols(str(output))
    missing = [name for name in FIXTURE_FUNCTIONS + (HEADER_SYMBOL, FIXTURE_ZERO_FILL_SYMBOL) if name not in symbols]
    assert not missing, f"fixture image lacks expected symbols: {missing}"
    for name in FIXTURE_FUNCTIONS:
        assert symbols[name][0] == "T", f"{name} is not an external text symbol: {symbols[name]}"
    return FixtureImage(
        path=str(output),
        header=symbols[HEADER_SYMBOL][1],
        functions={name: symbols[name][1] for name in FIXTURE_FUNCTIONS},
        zero_fill=symbols[FIXTURE_ZERO_FILL_SYMBOL][1],
    )


@pytest.fixture()
def doc(bound_executable: str, fixture_image: FixtureImage):
    with macscope.open(fixture_image.path, executable=bound_executable) as document:
        yield document


def test_info_identifies_fixture(doc, fixture_image):
    info = doc.info()
    assert info["format"] == "Mach-O executable"
    assert info["architecture"] == "arm64"
    assert info["name"] == Path(fixture_image.path).name
    assert info["functionCount"] >= len(fixture_image.functions)


def test_functions_match_nm(doc, fixture_image):
    found = {f.name: f for f in doc.functions()}
    for name, address in fixture_image.functions.items():
        assert name in found, f"{name} not enumerated"
        # Addresses are coerced from "0x…" strings to ints; records allow attribute access.
        assert isinstance(found[name].address, int)
        assert found[name].address == address
        assert found[name].end > found[name].address
    assert len(doc.functions(limit=2)) == 2


def test_read_bytes_match_file_and_decoder(doc, fixture_image):
    address = fixture_image.functions["_macscope_fixture_add"]
    data = doc.read_bytes(address, 16)
    assert isinstance(data, bytes) and len(data) == 16
    # A linked executable maps __TEXT from file offset 0 at the header's address.
    with open(fixture_image.path, "rb") as handle:
        handle.seek(address - fixture_image.header)
        assert data == handle.read(16)
    # The first instruction's bytes (the decoder's view) must prefix the raw read.
    first = doc.instructions(address=address, count=1)[0]
    assert data.hex().startswith(first.bytes.replace(" ", ""))


def test_instruction_operands_stay_strings(doc, fixture_image):
    # Operands (incl. bare "0x…" branch targets) must never be coerced to ints.
    rows = doc.instructions(address=fixture_image.functions["_macscope_fixture_twice"], count=4)
    assert rows
    assert all(isinstance(r.operands, str) for r in rows)
    assert all(isinstance(r.mnemonic, str) for r in rows)


def test_sections_and_zerofill(doc, fixture_image):
    sections = {s.name: s for s in doc.sections()}
    text = sections["__TEXT,__text"]
    for address in fixture_image.functions.values():
        assert text.address <= address < text.address + text.size
    # The zero-initialized array lives in a zero-fill section; reads return zeros.
    holder = [
        s for s in sections.values()
        if s.address <= fixture_image.zero_fill < s.address + s.size
    ]
    assert len(holder) == 1 and holder[0].zeroFill is True
    assert doc.read_bytes(fixture_image.zero_fill, 8) == b"\x00" * 8


def test_imports_exports_resolve(doc, fixture_image):
    assert any(i.name == FIXTURE_IMPORT for i in doc.imports())
    exported = {e.name: e.address for e in doc.exports()}
    for name, address in fixture_image.functions.items():
        assert exported.get(name) == address
    assert doc.resolve_symbol(HEADER_SYMBOL) == fixture_image.header


def test_rename_then_query_by_new_name(doc, fixture_image):
    # A rename is applied in the live session (undoable, not persisted) and the new name
    # becomes queryable: name-at, resolve-symbol and the function list all reflect it.
    address = fixture_image.functions["_macscope_fixture_add"]
    assert doc.resolve_symbol(RENAMED) is None
    result = doc.rename(address, RENAMED)
    assert result["ok"] is True and result["address"] == address
    assert doc.name_at(address) == RENAMED
    assert doc.resolve_symbol(RENAMED) == address
    names = {f.address: f.name for f in doc.functions()}
    assert names[address] == RENAMED
    assert "_macscope_fixture_add" not in names.values()
    first = doc.instructions(address=doc.resolve_symbol(RENAMED), count=1)[0]
    assert first.address == address


def test_run_script_batch(doc, fixture_image):
    results = doc.run_script([
        {"command": "info"},
        {"command": "functions", "arguments": {"limit": 2}},
    ])
    assert results[0]["functionCount"] == doc.info()["functionCount"]
    assert len(results[1]) == 2


def test_unknown_command_raises(doc):
    with pytest.raises(macscope.MacScopeError):
        doc.command("not-a-real-command")


def test_close_reaps_child_and_closes_pipes(bound_executable, fixture_image):
    document = macscope.Document(fixture_image.path, executable=bound_executable)
    process = document._client._proc
    assert document.info()["format"] == "Mach-O executable"
    document.close()
    # stdin EOF lets the server exit by itself; a clean close is exit status 0.
    assert process.returncode == 0
    assert all(stream is None or stream.closed for stream in (process.stdin, process.stdout, process.stderr))
    with pytest.raises(ChildProcessError):
        os.waitpid(process.pid, os.WNOHANG)
    document.close()  # idempotent
