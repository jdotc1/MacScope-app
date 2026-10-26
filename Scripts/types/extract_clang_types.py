#!/usr/bin/env python3
"""Extract one bounded, include-free authored header into SDKTypeArchive v1.

libclang is loaded only by a subprocess. No compiler plugin, AST serialization,
function body execution, SDK crawl or shipped compiler dependency is involved.
This first adapter deliberately refuses includes; framework closure is later work.
C API declarations: https://clang.llvm.org/docs/LibClang.html and clang-c/Index.h.
"""
from __future__ import annotations

import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import clang_import_configuration as configuration

MAX_SOURCE = 256 * 1024
MAX_ARCHIVE = 16 * 1024 * 1024
MAX_NODES = 10_000
MAX_FIELDS = 4096
WORKER_SECONDS = 30


class ExtractionError(ValueError):
    pass


class CXString(C.Structure):
    _fields_ = [("data", C.c_void_p), ("private_flags", C.c_uint)]


class CXCursor(C.Structure):
    _fields_ = [("kind", C.c_uint), ("xdata", C.c_int), ("data", C.c_void_p * 3)]


class CXType(C.Structure):
    _fields_ = [("kind", C.c_uint), ("data", C.c_void_p * 2)]


class CXLocation(C.Structure):
    _fields_ = [("ptr_data", C.c_void_p * 2), ("int_data", C.c_uint)]


class CXUnsavedFile(C.Structure):
    _fields_ = [("filename", C.c_char_p), ("contents", C.c_char_p), ("length", C.c_ulong)]


CHILD_VISITOR = C.CFUNCTYPE(C.c_uint, CXCursor, CXCursor, C.c_void_p)
FIELD_VISITOR = C.CFUNCTYPE(C.c_uint, CXCursor, C.c_void_p)


class Clang:
    def __init__(self, library: Path):
        self.lib = C.CDLL(str(library))
        declarations = {
            "createIndex": (C.c_void_p, [C.c_int, C.c_int]),
            "disposeIndex": (None, [C.c_void_p]),
            "parseTranslationUnit2": (C.c_int, [C.c_void_p, C.c_char_p, C.POINTER(C.c_char_p), C.c_int,
                                               C.POINTER(CXUnsavedFile), C.c_uint, C.c_uint, C.POINTER(C.c_void_p)]),
            "disposeTranslationUnit": (None, [C.c_void_p]),
            "getTranslationUnitCursor": (CXCursor, [C.c_void_p]),
            "getClangVersion": (CXString, []), "getCString": (C.c_char_p, [CXString]),
            "disposeString": (None, [CXString]),
            "visitChildren": (C.c_uint, [CXCursor, CHILD_VISITOR, C.c_void_p]),
            "Type_visitFields": (C.c_uint, [CXType, FIELD_VISITOR, C.c_void_p]),
            "getCursorType": (CXType, [CXCursor]), "getTypeDeclaration": (CXCursor, [CXType]),
            "getCursorSpelling": (CXString, [CXCursor]), "getCursorUSR": (CXString, [CXCursor]),
            "getTypeSpelling": (CXString, [CXType]), "getCanonicalType": (CXType, [CXType]),
            "Type_getNamedType": (CXType, [CXType]), "getPointeeType": (CXType, [CXType]),
            "getArrayElementType": (CXType, [CXType]), "getArraySize": (C.c_longlong, [CXType]),
            "getTypedefDeclUnderlyingType": (CXType, [CXCursor]),
            "getEnumDeclIntegerType": (CXType, [CXCursor]),
            "getEnumConstantDeclValue": (C.c_longlong, [CXCursor]),
            "getEnumConstantDeclUnsignedValue": (C.c_ulonglong, [CXCursor]),
            "Type_getSizeOf": (C.c_longlong, [CXType]), "Type_getAlignOf": (C.c_longlong, [CXType]),
            "Cursor_getOffsetOfField": (C.c_longlong, [CXCursor]),
            "Cursor_isAnonymousRecordDecl": (C.c_uint, [CXCursor]),
            "Cursor_isBitField": (C.c_uint, [CXCursor]), "getFieldDeclBitWidth": (C.c_int, [CXCursor]),
            "isConstQualifiedType": (C.c_uint, [CXType]), "isVolatileQualifiedType": (C.c_uint, [CXType]),
            "isRestrictQualifiedType": (C.c_uint, [CXType]),
            "getCursorLocation": (CXLocation, [CXCursor]),
            "getSpellingLocation": (None, [CXLocation, C.POINTER(C.c_void_p), C.POINTER(C.c_uint), C.POINTER(C.c_uint), C.POINTER(C.c_uint)]),
            "getFileName": (CXString, [C.c_void_p]),
            "getNumDiagnostics": (C.c_uint, [C.c_void_p]), "getDiagnostic": (C.c_void_p, [C.c_void_p, C.c_uint]),
            "getDiagnosticSeverity": (C.c_uint, [C.c_void_p]), "getDiagnosticSpelling": (CXString, [C.c_void_p]),
            "disposeDiagnostic": (None, [C.c_void_p]),
        }
        for name, (result, arguments) in declarations.items():
            try:
                function = getattr(self.lib, "clang_" + name)
            except AttributeError as error:
                raise ExtractionError("required libclang capability missing: " + name) from error
            function.restype, function.argtypes = result, arguments
            setattr(self, name, function)

    def string(self, value: CXString) -> str:
        try:
            result = (self.getCString(value) or b"").decode("utf-8", "strict")
            if len(result.encode()) > 16384:
                raise ExtractionError("libclang string exceeds bound")
            return result
        finally:
            self.disposeString(value)

    def children(self, cursor: CXCursor) -> list[CXCursor]:
        result = []
        @CHILD_VISITOR
        def visit(child, parent, context):
            result.append(child)
            return 0 if len(result) > MAX_NODES else 1
        self.visitChildren(cursor, visit, None)
        if len(result) > MAX_NODES:
            raise ExtractionError("cursor count exceeds bound")
        return result

    def fields(self, kind: CXType) -> list[CXCursor]:
        result = []
        @FIELD_VISITOR
        def visit(field, context):
            result.append(field)
            return 0 if len(result) > MAX_FIELDS else 1
        self.Type_visitFields(kind, visit, None)
        if len(result) > MAX_FIELDS:
            raise ExtractionError("field count exceeds bound")
        return result

    def origin(self, cursor: CXCursor, source: Path) -> dict | None:
        file = C.c_void_p()
        line, column, offset = C.c_uint(), C.c_uint(), C.c_uint()
        self.getSpellingLocation(self.getCursorLocation(cursor), C.byref(file), C.byref(line), C.byref(column), C.byref(offset))
        if not file.value:
            return None
        path = Path(self.string(self.getFileName(file))).resolve()
        if path != source:
            raise ExtractionError("declaration outside the selected input")
        return {"header": source.name, "line": line.value, "column": column.value}


def checked_source(source: Path) -> bytes:
    if source.is_symlink() or not source.is_file() or source.stat().st_size > MAX_SOURCE:
        raise ExtractionError("input must be one bounded regular header")
    data = source.read_bytes()
    if len(data) > MAX_SOURCE:
        raise ExtractionError("input grew beyond bound")
    logical = data.decode("utf-8").replace("\\\r\n", "").replace("\\\n", "").replace("??=", "#").replace("%:", "#")
    logical = re.sub(r"/\*.*?\*/|//[^\n]*", " ", logical, flags=re.S)
    if re.search(r"(?m)^\s*#\s*(?:include|include_next|import|embed)\b", logical):
        raise ExtractionError("includes are outside this initial authored-header extractor")
    return data


def extract_in_worker(config: dict, source: Path, data: bytes) -> dict:
    if configuration.configuration_id(config) != config.get("configurationID"):
        raise ExtractionError("configuration identity mismatch")
    library = Path(config["compiler"]).parent.parent / "lib/libclang.dylib"
    clang = Clang(library)
    index = clang.createIndex(0, 0)
    if not index:
        raise ExtractionError("libclang index creation failed")
    unit = C.c_void_p()
    arguments = [arg.encode() for arg in config["arguments"]]
    argv = (C.c_char_p * len(arguments))(*arguments)
    filename = os.fsencode(source)
    unsaved = CXUnsavedFile(filename, data, len(data))
    try:
        error = clang.parseTranslationUnit2(index, filename, argv, len(arguments), C.byref(unsaved), 1, 0x40, C.byref(unit))
        if error or not unit.value:
            raise ExtractionError(f"libclang parse failed: CXErrorCode={error}")
        diagnostics, errors = [], []
        count = clang.getNumDiagnostics(unit)
        if count > 1024:
            raise ExtractionError("diagnostic count exceeds bound")
        for i in range(count):
            diagnostic = clang.getDiagnostic(unit, i)
            try:
                severity = clang.getDiagnosticSeverity(diagnostic)
                message = clang.string(clang.getDiagnosticSpelling(diagnostic))
                diagnostics.append(f"severity={severity}: {message}")
                if severity >= 3:
                    errors.append(message)
            finally:
                clang.disposeDiagnostic(diagnostic)
        if errors:
            raise ExtractionError("clang error diagnostics: " + "; ".join(errors)[:16384])
        pending, ids, nodes = [], {}, {}

        def normalize(kind):
            # Elaborated tag sugar carries no distinct layout. Typedefs remain nodes.
            return clang.Type_getNamedType(kind) if kind.kind == 119 else kind

        def ensure(kind):
            kind = normalize(kind)
            spelling = clang.string(clang.getTypeSpelling(kind)) or "<unknown>"
            declaration = clang.getTypeDeclaration(kind)
            origin = clang.origin(declaration, source)
            usr = clang.string(clang.getCursorUSR(declaration))
            # USRs are scoped hints. Anonymous declarations use input-relative location.
            hint = usr or spelling.replace(str(source), source.name)
            key = f"{kind.kind}:{hint}:{spelling.replace(str(source), source.name)}"
            if origin and not usr:
                key += f":{origin['header']}:{origin['line']}:{origin['column']}"
            if len(key.encode()) > 900:
                key = f"type:{kind.kind}:" + hashlib.sha256(key.encode()).hexdigest()
            if key not in ids:
                if len(ids) >= MAX_NODES:
                    raise ExtractionError("type count exceeds bound")
                ids[key] = key
                pending.append((key, kind, spelling.replace(str(source), source.name), declaration, origin))
            return key

        for cursor in clang.children(clang.getTranslationUnitCursor(unit)):
            if cursor.kind in (2, 3, 5, 20):  # struct, union, enum, typedef
                clang.origin(cursor, source)
                ensure(clang.getCursorType(cursor))
        position = 0
        while position < len(pending):
            key, kind, spelling, declaration, origin = pending[position]
            position += 1
            size, alignment = clang.Type_getSizeOf(kind), clang.Type_getAlignOf(kind)
            layout = ({"status": "known", "sizeBytes": size, "alignmentBytes": alignment}
                      if size >= 0 and alignment > 0 else
                      {"status": "unknown", "reason": f"libclang layout: size={size}, alignment={alignment}"})
            node = {"id": key, "kind": "opaque", "spelling": spelling, "layout": layout,
                    "fields": [], "enumValues": [], "qualifiers": []}
            if origin:
                node["origin"] = origin
            for name, query in (("const", clang.isConstQualifiedType), ("volatile", clang.isVolatileQualifiedType), ("restrict", clang.isRestrictQualifiedType)):
                if query(kind): node["qualifiers"].append(name)
            if 3 <= kind.kind <= 23:
                node["kind"] = "scalar"
                if kind.kind <= 20:
                    node["signed"] = kind.kind >= 13
            elif kind.kind == 101:
                node.update(kind="pointer", pointeeTypeID=ensure(clang.getPointeeType(kind)))
            elif kind.kind == 105:
                node.update(kind="record", recordKind="union" if declaration.kind == 3 else "struct")
                for i, field in enumerate(clang.fields(kind)):
                    field_type = clang.getCursorType(field)
                    anonymous = bool(clang.Cursor_isAnonymousRecordDecl(clang.getTypeDeclaration(normalize(field_type))))
                    name = "" if anonymous else clang.string(clang.getCursorSpelling(field)).replace(str(source), source.name)
                    offset = clang.Cursor_getOffsetOfField(field)
                    item = {"id": f"{key}/field:{i}", "name": name, "typeID": ensure(field_type),
                            "flexibleArray": field_type.kind == 114, "anonymous": anonymous}
                    if offset >= 0:
                        item["bitOffset"] = offset
                    else:
                        node["layout"] = {"status": "unknown", "reason": f"libclang field offset error: {offset}"}
                    if clang.Cursor_isBitField(field):
                        width = clang.getFieldDeclBitWidth(field)
                        if width < 0:
                            raise ExtractionError("bitfield width unavailable")
                        item["bitWidth"] = width
                    node["fields"].append(item)
            elif kind.kind == 106:
                base = clang.getEnumDeclIntegerType(declaration)
                node.update(kind="enumeration", underlyingTypeID=ensure(base))
                signed = clang.getCanonicalType(base).kind >= 13
                for child in clang.children(declaration):
                    if child.kind == 7:
                        value = clang.getEnumConstantDeclValue(child) if signed else clang.getEnumConstantDeclUnsignedValue(child)
                        node["enumValues"].append({"name": clang.string(clang.getCursorSpelling(child)), "value": str(value)})
            elif kind.kind == 107:
                node.update(kind="typedef", underlyingTypeID=ensure(clang.getTypedefDeclUnderlyingType(declaration)))
            elif kind.kind in (112, 114):
                node.update(kind="array", elementTypeID=ensure(clang.getArrayElementType(kind)))
                count = clang.getArraySize(kind)
                if count >= 0: node["arrayCount"] = count
                else: node["layout"] = {"status": "unknown", "reason": "incomplete array extent"}
            else:
                node["layout"] = {"status": "unknown", "reason": f"type kind {kind.kind} is display-only; prototype/ABI support deferred"}
            canonical = ensure(clang.getCanonicalType(kind))
            if canonical != key: node["canonicalTypeID"] = canonical
            nodes[key] = node
        doc = {"schema": "macscope.sdk-type-archive", "schemaMajor": 1, "schemaMinor": 0,
               "configurationID": config["configurationID"],
               "provenance": {"compiler": config["compiler"], "compilerVersion": config["compilerVersion"],
                              "libclangVersion": clang.string(clang.getClangVersion()),
                              "sdkIdentity": f"{config['sdkPath']}|{config['sdkVersion']}|{config['sdkBuild']}",
                              "targetTriple": config["profile"]["target"], "language": config["profile"]["language"],
                              "extractorVersion": configuration.EXTRACTOR_VERSION, "input": source.name,
                              "inputSHA256": hashlib.sha256(data).hexdigest(), "arguments": config["arguments"]},
               "diagnostics": diagnostics + ["Semantic annotations and complete function prototypes are not extracted in v1."],
               "types": [nodes[key] for key in sorted(nodes)]}
        validate_archive(doc)
        return doc
    finally:
        if unit.value: clang.disposeTranslationUnit(unit)
        clang.disposeIndex(index)


def validate_archive(doc: dict) -> None:
    """Producer-side v1 checks; the Swift loader independently validates admission."""
    encoded = configuration.canonical_json(doc)
    if len(encoded) > MAX_ARCHIVE or doc.get("schema") != "macscope.sdk-type-archive" or (doc.get("schemaMajor"), doc.get("schemaMinor")) != (1, 0):
        raise ExtractionError("archive schema/byte bound")
    stack = [doc]
    work = 0
    while stack:
        value = stack.pop(); work += 1
        if work > 1_000_000: raise ExtractionError("archive work bound")
        if isinstance(value, str) and (len(value.encode()) > 16384 or "\0" in value):
            raise ExtractionError("archive string bound")
        if isinstance(value, dict): stack.extend(value.keys()); stack.extend(value.values())
        elif isinstance(value, list): stack.extend(value)
    types = doc["types"]
    if len(types) > MAX_NODES:
        raise ExtractionError("archive node bound")
    nodes = {node["id"]: node for node in types}
    if len(nodes) != len(types):
        raise ExtractionError("duplicate type identity")
    pending, users = {}, {}
    carrier_work = 0
    def integer_carrier(key):
        nonlocal carrier_work
        visited = set()
        while key not in visited:
            visited.add(key); carrier_work += 1
            if carrier_work > 100_000: raise ExtractionError("carrier work bound")
            node = nodes[key]
            if node["kind"] == "scalar": return type(node.get("signed")) is bool
            if node["kind"] not in ("typedef", "enumeration"): return False
            key = node["underlyingTypeID"]
        return False
    for node in types:
        layout, kind = node["layout"], node["kind"]
        known = layout["status"] == "known"
        if known:
            size, align = layout["sizeBytes"], layout["alignmentBytes"]
            if type(size) is not int or type(align) is not int or not 0 <= size <= (2**64 - 1)//8 or align <= 0 or align & (align-1) or size % align:
                raise ExtractionError("invalid known layout")
        elif layout.get("reason") is None or "sizeBytes" in layout or "alignmentBytes" in layout:
            raise ExtractionError("invalid unknown layout")
        refs = [node[name] for name in ("canonicalTypeID", "underlyingTypeID", "pointeeTypeID", "elementTypeID") if name in node]
        refs += [field["typeID"] for field in node["fields"]]
        if any(ref not in nodes for ref in refs):
            raise ExtractionError("dangling type reference")
        required = []
        if kind == "record":
            for index, field in enumerate(node["fields"]):
                carrier = nodes[field["typeID"]]
                if "bitWidth" in field and not integer_carrier(field["typeID"]):
                    raise ExtractionError("noninteger bitfield")
                if field["flexibleArray"]:
                    if node["recordKind"] != "struct" or index != len(node["fields"])-1 or carrier["kind"] != "array" or "arrayCount" in carrier:
                        raise ExtractionError("invalid flexible tail")
                else: required.append(field["typeID"])
                if known:
                    offset = field.get("bitOffset")
                    extent = 0 if field["flexibleArray"] else field.get("bitWidth", carrier["layout"].get("sizeBytes", -1)*8)
                    if type(offset) is not int or offset < 0 or extent < 0 or offset + extent > size*8 or (node["recordKind"] == "union" and offset != 0):
                        raise ExtractionError("invalid field bit extent")
        elif kind in ("typedef", "enumeration"):
            required.append(node["underlyingTypeID"])
            if known and layout != nodes[required[0]]["layout"]:
                raise ExtractionError("underlying layout mismatch")
        elif kind == "array":
            if "arrayCount" in node:
                required.append(node["elementTypeID"])
                element = nodes[required[0]]["layout"]
                if known and (element.get("sizeBytes", -1)*node["arrayCount"] != size or element.get("alignmentBytes") != align):
                    raise ExtractionError("array layout mismatch")
            elif known: raise ExtractionError("unknown array extent")
        elif kind == "opaque" and known:
            raise ExtractionError("opaque layout cannot be authoritative")
        if known:
            for ref in required:
                if nodes[ref]["layout"]["status"] != "known":
                    raise ExtractionError("incomplete by-value dependency")
                users.setdefault(ref, []).append(node["id"])
            pending[node["id"]] = len(required)
    queue = [key for key, degree in pending.items() if degree == 0]
    for key in queue:
        for user in users.get(key, []):
            pending[user] -= 1
            if pending[user] == 0: queue.append(user)
    if len(queue) != len(pending):
        raise ExtractionError("by-value layout cycle")


def run_worker(config: dict, source: Path, directory: Path) -> dict:
    job = directory / "job.json"
    job.write_bytes(configuration.canonical_json({"configuration": config, "source": str(source)}))
    with (directory / "worker.stdout").open("wb") as stdout, (directory / "worker.stderr").open("wb") as stderr:
        result = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--worker", str(job)],
                                stdout=stdout, stderr=stderr, env=configuration.CLEAN_ENV, timeout=WORKER_SECONDS, check=False)
    errors = (directory / "worker.stderr").read_bytes()[:16384].decode("utf-8", "replace")
    if result.returncode:
        raise ExtractionError(f"libclang worker failed ({result.returncode}): {errors}")
    output = directory / "worker.stdout"
    if output.stat().st_size > MAX_ARCHIVE:
        raise ExtractionError("worker output exceeds bound")
    return json.loads(output.read_bytes())


def extract(profile: dict, source: Path, output: Path, *, resolve=configuration.resolve_configuration, worker=run_worker) -> dict:
    data = checked_source(source)
    source = source.resolve(strict=True)
    config = resolve(profile, source.parent)
    output = output.parent.resolve(strict=True) / output.name
    if output.is_symlink() or output == source:
        raise ExtractionError("output must not replace a symlink or input")
    with tempfile.TemporaryDirectory(prefix=".clang-types-", dir=output.parent) as temporary:
        directory = Path(temporary)
        doc = worker(config, source, directory)
        validate_archive(doc)
        if doc["configurationID"] != config["configurationID"] or doc["provenance"]["inputSHA256"] != hashlib.sha256(data).hexdigest():
            raise ExtractionError("worker input/configuration identity changed")
        payload = configuration.canonical_json(doc) + b"\n"
        staged = directory / "archive.json"
        with staged.open("wb") as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(staged, output)
    return doc


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        resource.setrlimit(resource.RLIMIT_CPU, (20, 25))
        resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_ARCHIVE, MAX_ARCHIVE))
        # Darwin may reject RLIMIT_DATA despite reporting an unlimited ceiling.
        # ctypes releases the GIL during parsing, so this worker-local watchdog
        # can terminate a runaway parse. Sampling is not an exact allocation cap.
        def memory_watchdog():
            while True:
                peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
                peak_bytes = peak if sys.platform == "darwin" else peak * 1024
                if peak_bytes > 512 * 1024 * 1024:
                    os._exit(125)
                time.sleep(0.05)
        threading.Thread(target=memory_watchdog, daemon=True).start()
        if args.worker.stat().st_size > 128 * 1024:
            raise ExtractionError("worker request exceeds bound")
        job = json.loads(args.worker.read_bytes())
        source = Path(job["source"])
        print(configuration.canonical_json(extract_in_worker(job["configuration"], source, checked_source(source))).decode())
    else:
        if not all((args.profile, args.input, args.output)):
            parser.error("--profile, --input and --output are required")
        started = time.monotonic()
        doc = extract(configuration.load_profile(args.profile), args.input, args.output)
        print(json.dumps({"output": str(args.output), "types": len(doc["types"]), "seconds": time.monotonic()-started}))


if __name__ == "__main__":
    try:
        main()
    except (ExtractionError, configuration.ConfigurationError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
