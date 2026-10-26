#!/usr/bin/env python3
"""HOP-5 step 2: offline generator for MacScope's SDK call-signature pack.

Parses a BOUNDED, LISTED set of macOS SDK headers (see FAMILIES) with the active
toolchain's clang (`-Xclang -ast-dump=json -fsyntax-only`, one umbrella TU per
family) and writes the versioned JSON pack that `CallSignaturePack.load` reads
(`macscope.call-signature-pack`, formatVersion 1).

Per entry: undecorated C name (the binary symbol without its one leading `_`),
return type, parameter types/names (source spelling, nullability/restrict
stripped), `variadic`, `noReturn` (`__attribute__((noreturn))`, `_Noreturn`,
`[[noreturn]]`), the `format` attribute (kind, format-string index, first
variadic index; 1-based, as declared) when present, a calling-convention note,
and the source family. The SDK name and version are recorded in the header.

Offline and deterministic: only the local SDK and toolchain are read, nothing is
fetched, entries are sorted by name, and no timestamp is written. `--check`
regenerates in memory and diffs against the committed pack (exit 1 on drift).
The text AST dump is used only for the `format` attribute's arguments, which
the JSON dump omits.

Python 3.9 compatible; standard library only.
"""

import argparse
import difflib
import hashlib
import collections
import shlex
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPO_ROOT / "MacScope" / "Resources" / "SDKCallSignaturePack.json"
FORMAT_IDENTIFIER = "macscope.call-signature-pack"
FORMAT_VERSION = 1
TOOL = "Scripts/signatures/generate_sdk_signature_pack.py"
MAX_PARAMETERS = 64

# The bounded header set. Each family is one translation unit; only FunctionDecls
# whose spelling file (relative to the SDK root) matches one of `files` are kept,
# so transitively included headers of OTHER families never leak in. Earlier
# families win a duplicate name.
FAMILIES = [
    {
        "name": "libc",
        "language": "c",
        "includes": ["stdio.h", "stdlib.h", "string.h", "strings.h", "unistd.h",
                     "err.h", "setjmp.h", "assert.h", "signal.h", "math.h", "time.h",
                     "fcntl.h", "sys/socket.h", "sys/stat.h", "sys/mman.h", "sys/event.h",
                     "sys/mount.h", "sys/resource.h", "sys/sysctl.h", "sys/xattr.h", "sys/wait.h",
                     "dirent.h", "dlfcn.h", "spawn.h", "netdb.h", "arpa/inet.h", "ifaddrs.h",
                     "pwd.h", "grp.h", "wchar.h", "wctype.h", "locale.h", "xlocale.h",
                     "regex.h", "glob.h", "fts.h", "ftw.h", "aio.h", "semaphore.h",
                     "copyfile.h", "removefile.h", "libproc.h", "notify.h", "mach/mach.h",
                     "mach/mach_time.h", "malloc/malloc.h", "os/lock.h", "os/activity.h"],
        "files": [r"usr/include/[^/]+\.h", r"usr/include/(sys|secure|malloc|mach|arpa|os)/[^/]+\.h"],
        "exclude": [r"usr/include/pthread[^/]*\.h"],
        "defines": [],
    },
    {
        "name": "pthread",
        "language": "c",
        "includes": ["pthread.h"],
        "files": [r"usr/include/pthread\.h", r"usr/include/pthread/[^/]+\.h"],
        "exclude": [],
        "defines": [],
    },
    {
        "name": "dispatch",
        "language": "c",
        "includes": ["dispatch/dispatch.h"],
        "files": [r"usr/include/dispatch/[^/]+\.h"],
        "exclude": [],
        "defines": [],
    },
    {
        "name": "oslog",
        "language": "c",
        "includes": ["os/log.h", "os/signpost.h"],
        "files": [r"usr/include/os/[^/]+\.h"],
        "exclude": [],
        "defines": [],
    },
    {
        "name": "objc-runtime",
        "language": "objective-c",
        "includes": ["objc/runtime.h", "objc/message.h", "objc/objc-exception.h"],
        "files": [r"usr/include/objc/(runtime|message|objc-exception|objc)\.h"],
        "exclude": [],
        # objc-api.h forces `void objc_msgSend(void)` on arm64; parse this family for x86_64 with
        # the old dispatch prototypes so objc_msgSend & co. carry `id (id, SEL, ...)`. The
        # declarations are architecture-neutral C prototypes.
        "defines": ["OBJC_OLD_DISPATCH_PROTOTYPES=1"],
        "target": "x86_64-apple-macos",
    },
    {
        "name": "corefoundation",
        "language": "c",
        "includes": ["CoreFoundation/CoreFoundation.h"],
        "files": [r"System/Library/Frameworks/CoreFoundation\.framework/Headers/[^/]+\.h"],
        "exclude": [],
        "defines": [],
    },
    {
        "name": "foundation",
        "language": "objective-c",
        "includes": ["Foundation/Foundation.h"],
        "files": [r"System/Library/Frameworks/Foundation\.framework/Headers/[^/]+\.h"],
        "exclude": [],
        "defines": [],
    },
]

# Public, bounded umbrella headers only; no installed binaries or prevalence scan.
for name, framework, includes, language in [
    ("security", "Security", ["Security.h", "SecCode.h", "SecStaticCode.h", "SecRequirement.h",
      "SecTask.h", "SecTransform.h", "SecProtocolOptions.h", "SecProtocolMetadata.h"], "objective-c"),
    ("iokit", "IOKit", ["IOKitLib.h", "IODataQueueClient.h", "IOCFPlugIn.h", "IOCFSerialize.h",
      "IOCFUnserialize.h", "hid/IOHIDManager.h", "hid/IOHIDDevice.h", "hid/IOHIDQueue.h",
      "hid/IOHIDValue.h", "hid/IOHIDElement.h", "ps/IOPowerSources.h", "pwr_mgt/IOPMLib.h",
      "network/IONetworkLib.h", "kext/KextManager.h", "graphics/IOGraphicsLib.h"], "c"),
    ("coregraphics", "CoreGraphics", ["CoreGraphics.h"], "objective-c"),
    ("metal", "Metal", ["Metal.h", "MTLIOCompressor.h"], "objective-c"),
]:
    FAMILIES.append({"name": name, "language": language,
                     "includes": [framework + "/" + h for h in includes],
                     "files": [r"System/Library/Frameworks/" + framework + r"\.framework/Headers/.+\.h"],
                     "exclude": [], "defines": []})


TYPE_NOISE = re.compile(
    r"\b(?:__restrict|restrict|_Nonnull|_Nullable_result|_Nullable|_Null_unspecified|"
    r"__nonnull|__nullable|__null_unspecified|__kindof)\b"
)
TRAILING_ATTRIBUTES = re.compile(r"(?:\s*__attribute__\(\([^()]*(?:\([^()]*\))*[^()]*\)\))+\s*$")
NORETURN_ATTRS = {"NoReturnAttr", "C11NoReturnAttr", "CXX11NoReturnAttr"}
TEXT_NODE = re.compile(r"^(?P<prefix>[ |`-]*)(?P<kind>[A-Za-z0-9]+) 0x[0-9a-f]+ (?P<rest>.*)$")
TEXT_FUNCTION_NAME = re.compile(r" (?P<name>[A-Za-z_$][A-Za-z0-9_$]*) '")
TEXT_FORMAT = re.compile(r" (?P<kind>[A-Za-z_][A-Za-z0-9_]*) (?P<fmt>\d+) (?P<first>\d+)$")


def run(command: List[str]) -> str:
    return subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True).stdout.strip()


def sdk_identity() -> Tuple[Path, str, str]:
    path = Path(run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]))
    version = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    resolved = path.resolve().name
    name = resolved if re.search(r"\d", resolved) else "MacOSX%s.sdk" % version
    return path, name, version


def clean_type(spelling: str) -> str:
    spelling = TYPE_NOISE.sub("", spelling)
    spelling = re.sub(r"\s+", " ", spelling).strip()
    spelling = re.sub(r"\s+([,)\]])", r"\1", spelling)
    spelling = re.sub(r"\(\s+", "(", spelling)
    spelling = re.sub(r"\*\s+\*", "**", spelling)
    spelling = re.sub(r"\*\s+\)", "*)", spelling)
    return spelling.strip()


def parameter_name(name: Optional[str], index: int) -> str:
    """Header parameter names without the reserved-identifier underscores (`__fd` -> `fd`)."""
    stripped = (name or "").lstrip("_")
    return stripped if stripped else "arg%d" % index


def matching_paren(text: str, start: int) -> int:
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    return -1


def return_type(function_type: str) -> Optional[str]:
    """Return type from a clang function-type spelling, e.g. `int (const char *, ...)` -> `int`,
    `void (*(int, void (*)(int)))(int)` -> `void (*)(int)`."""
    text = TRAILING_ATTRIBUTES.sub("", function_type).strip()
    open_index = text.find("(")
    if open_index <= 0:
        return None
    close_index = matching_paren(text, open_index)
    if close_index < 0:
        return None
    head = text[:open_index].strip()
    if text[open_index + 1:open_index + 2] in ("*", "^"):
        inner = text[open_index + 1:close_index]
        marker = inner[0]
        params_open = inner.find("(")
        if params_open < 0 or inner[1:params_open].strip():
            return None
        return clean_type("%s (%s)%s" % (head, marker, text[close_index + 1:]))
    return clean_type(head) or None


class LocationTracker:
    """Clang's JSON dump writes a location's `file` only when it changes from the previously
    written location, so the current file must be tracked in document order."""

    def __init__(self) -> None:
        self.current = ""

    def bare(self, location: dict) -> str:
        if isinstance(location, dict) and "file" in location:
            self.current = location["file"]
        return self.current

    def location(self, location: dict) -> str:
        if not isinstance(location, dict):
            return self.current
        if "spellingLoc" in location or "expansionLoc" in location:
            self.bare(location.get("spellingLoc", {}))
            return self.bare(location.get("expansionLoc", {}))
        return self.bare(location)

    def node(self, node: dict) -> str:
        """Advance over a node's own locations (loc, then range begin/end); return the
        expansion file of its `loc`."""
        file = self.location(node.get("loc", {}))
        node_range = node.get("range", {})
        if isinstance(node_range, dict):
            self.location(node_range.get("begin", {}))
            self.location(node_range.get("end", {}))
        return file


def walk(node: dict, tracker: LocationTracker, out: List[Tuple[dict, str]],
         typedefs: Dict[str, str]) -> None:
    file = tracker.node(node)
    kind = node.get("kind")
    if kind == "FunctionDecl":
        out.append((node, file))
    elif kind == "EnumDecl" and node.get("fixedUnderlyingType"):
        scalar = node["fixedUnderlyingType"]["qualType"]
        if node.get("name"):
            typedefs["enum " + node["name"]] = scalar
        if node.get("id"):
            typedefs["@enum:" + node["id"]] = scalar
    elif kind == "TypedefDecl" and node.get("name") and isinstance(node.get("type"), dict):
        underlying = node["type"].get("desugaredQualType")
        if not underlying or underlying == node["name"]:
            underlying = node["type"].get("qualType")
        if underlying and underlying != node["name"]:
            typedefs.setdefault(node["name"], underlying)
            # OS_ENUM/NS_ENUM can declare an anonymous fixed-width enum, then name
            # it only through a TypedefDecl. Follow clang's declaration identity.
            pending = list(node.get("inner", ()))
            while pending:
                child = pending.pop()
                if child.get("kind") == "EnumType":
                    scalar = typedefs.get("@enum:" + child.get("decl", {}).get("id", ""))
                    if scalar:
                        typedefs[underlying] = scalar
                pending.extend(child.get("inner", ()))
    for child in node.get("inner", ()) or ():
        if isinstance(child, dict):
            walk(child, tracker, out, typedefs)


FLOATING = {"float", "double", "long double"}


SCALAR_ABI = {
    "void": "void", "_Bool": "uint8_t", "bool": "uint8_t", "char": "int8_t",
    "signed char": "int8_t", "unsigned char": "uint8_t", "short": "int16_t",
    "short int": "int16_t", "unsigned short": "uint16_t", "unsigned short int": "uint16_t",
    "int": "int", "signed int": "int", "unsigned int": "unsigned int",
    "long": "long", "long int": "long", "unsigned long": "unsigned long",
    "unsigned long int": "unsigned long", "long long": "long long",
    "long long int": "long long", "unsigned long long": "unsigned long long",
    "unsigned long long int": "unsigned long long", "float": "float", "double": "double",
    "long double": "double", "id": "id", "Class": "void *", "SEL": "SEL",
}


def resolved_type(spelling: str, typedefs: Dict[str, str]) -> Optional[str]:
    resolved = spelling
    visited = set()
    for _ in range(64):
        bare = re.sub(r"^(?:(?:const|volatile) )+", "", clean_type(resolved)).strip()
        if bare in visited:
            return None
        visited.add(bare)
        if bare in typedefs:
            resolved = typedefs[bare]
        else:
            return bare
    return None


def abi_scalar(spelling: str, typedefs: Dict[str, str]) -> Optional[str]:
    """Classify only proven one-register scalars/pointers on Darwin arm64.

    Aggregates, vectors, complex values, unresolved aliases and enum widths are rejected.
    Pointer-to-aggregate and callback types are valid single pointers, not aggregates.
    """
    bare = resolved_type(spelling, typedefs)
    if not bare:
        return None
    if "ext_vector_type" in bare or "vector_size" in bare or "_Complex" in bare or "__int128" in bare:
        return None
    if "*" in bare or "^" in bare:
        return spelling
    if bare.startswith("id<"):
        return "id"
    return SCALAR_ABI.get(bare)


def abi_type(spelling: str, typedefs: Dict[str, str]) -> Optional[str]:
    scalar = abi_scalar(spelling, typedefs)
    if scalar is None:
        return None
    return scalar if scalar in FLOATING else spelling


def clang_command(sdk: Path, family: dict, source: Path, dump: str) -> List[str]:
    command = ["xcrun", "--sdk", "macosx", "clang", "-x", family["language"], "-fsyntax-only",
               "-isysroot", str(sdk), "-target", family.get("target", "arm64-apple-macos"), "-fblocks",
               "-Wno-everything", "-Xclang", dump]
    for define in family["defines"]:
        command += ["-D", define]
    return command + [str(source)]


def format_attributes(text_dump: Iterable[str]) -> Dict[str, Tuple[str, int, int]]:
    """FormatAttr arguments by function name from the text AST dump (redeclarations agree)."""
    formats: Dict[str, Tuple[str, int, int]] = {}
    function_depth = -1
    function_name = None
    for line in text_dump:
        match = TEXT_NODE.match(line)
        if not match:
            continue
        depth = len(match.group("prefix"))
        kind = match.group("kind")
        if kind == "FunctionDecl":
            name_match = TEXT_FUNCTION_NAME.search(match.group("rest"))
            function_depth, function_name = depth, (name_match.group("name") if name_match else None)
        elif depth <= function_depth:
            function_depth, function_name = -1, None
        elif kind == "FormatAttr" and function_name and depth == function_depth + 2:
            format_match = TEXT_FORMAT.search(match.group("rest"))
            if format_match:
                formats.setdefault(function_name, (format_match.group("kind"),
                                                   int(format_match.group("fmt")),
                                                   int(format_match.group("first"))))
    return formats


def ast_inputs(sdk: Path, family: dict, scratch: Path) -> Tuple[dict, str, dict]:
    """Retain each new SDK AST and its once-hashed header provenance for parser iterations.

    The cache key identifies SDK path, version, compiler version and TU options. This is an
    offline generation cache, not a verification receipt: --check never reopens SDK headers.
    """
    identity = {"sdk": str(sdk), "sdkVersion": run(["xcrun", "--show-sdk-version"]),
                "clang": run(["xcrun", "clang", "--version"]), "family": family}
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:20]
    cache = scratch / (family["name"] + "-" + key)
    cache.mkdir(parents=True, exist_ok=True)
    json_path, text_path, provenance_path = [cache / n for n in ("ast.json", "ast.txt", "provenance.json")]
    if provenance_path.exists() and json_path.exists() and text_path.exists():
        return json.loads(json_path.read_bytes()), text_path.read_text(), json.loads(provenance_path.read_text())
    if os.environ.get("MACSCOPE_SDK_REQUIRE_RETAINED_AST") == "1":
        raise RuntimeError("Missing retained SDK AST for " + family["name"] + "; explicitly generate new inputs first")
    source = cache / ("headers.m" if family["language"] == "objective-c" else "headers.c")
    source.write_text("".join("#include <%s>\n" % h for h in family["includes"]))
    dep = cache / "headers.d"
    with json_path.open("wb") as output:
        subprocess.run(clang_command(sdk, family, source, "-ast-dump=json") +
                       ["-MD", "-MF", str(dep)], check=True, stdout=output, stderr=subprocess.PIPE)
    with text_path.open("w") as output:
        subprocess.run(clang_command(sdk, family, source, "-ast-dump"), check=True,
                       stdout=output, stderr=subprocess.PIPE)
    # Reuse every previously recorded header digest across overlapping umbrella TUs.
    known_headers = {}
    for prior in sorted(scratch.glob("*/provenance.json")):
        for record in json.loads(prior.read_text())["headers"]:
            known_headers[record["path"]] = record
    headers = []
    dependencies = shlex.split(dep.read_text().replace("\\\n", " ").split(":", 1)[1])
    for path in sorted(set(dependencies)):
        header = Path(path)
        try:
            relative = str(header.relative_to(sdk))
        except ValueError:
            # Clang resource headers are source dependencies too; retain portable paths.
            if "/lib/clang/" not in path:
                continue
            relative = "clang/" + path.split("/lib/clang/", 1)[1]
        record = known_headers.get(relative)
        if record is None:
            data = header.read_bytes()
            record = {"path": relative, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        headers.append(record)
    provenance = {"sdkVersion": identity["sdkVersion"], "clang": identity["clang"].splitlines()[0],
                  "target": family.get("target", "arm64-apple-macos"), "headers": headers}
    provenance_path.write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
    return json.loads(json_path.read_bytes()), text_path.read_text(), provenance


def declaration_annotations(lines: Iterable[str]) -> Dict[str, dict]:
    """Read clang's semantic attributes (not macro text) from the same declarations."""
    result = {}
    current, depth = None, -1
    for line in lines:
        match = TEXT_NODE.match(line)
        if not match:
            continue
        node_depth, kind = len(match["prefix"]), match["kind"]
        if kind == "FunctionDecl":
            name = TEXT_FUNCTION_NAME.search(match["rest"])
            current, depth = (name["name"] if name else None), node_depth
        elif node_depth <= depth:
            current, depth = None, -1
        elif current and node_depth == depth + 2:
            record = result.setdefault(current, {"ownership": [], "availability": []})
            if kind in {"CFReturnsRetainedAttr", "CFReturnsNotRetainedAttr", "CFReturnsAutoreleasedAttr",
                        "NSReturnsRetainedAttr", "NSReturnsNotRetainedAttr", "NSReturnsAutoreleasedAttr"}:
                record["ownership"].append(kind.removesuffix("Attr"))
            elif kind == "AvailabilityAttr":
                # Everything after the final location '>' is stable semantic data.
                value = match["rest"].rsplit(">", 1)[-1].strip()
                value = re.sub(r"^(?:Inherited |Implicit )+", "", value)
                record["availability"].append(value)
    return {name: {k: sorted(set(v)) for k, v in record.items() if v}
            for name, record in result.items()}


def collect_family(sdk: Path, family: dict, scratch: Path,
                   rejections: Optional[List[dict]] = None,
                   provenance_out: Optional[dict] = None) -> Dict[str, dict]:
    root, text_dump, provenance = ast_inputs(sdk, family, scratch)
    formats = format_attributes(text_dump.splitlines())
    annotations = declaration_annotations(text_dump.splitlines())
    if provenance_out is not None:
        provenance_out[family["name"]] = provenance
    del text_dump
    rejections = rejections if rejections is not None else []

    sdk_prefix = str(sdk.resolve()).rstrip("/") + "/"
    sdk_alias = str(sdk).rstrip("/") + "/"
    allowed = [re.compile(pattern + r"$") for pattern in family["files"]]
    excluded = [re.compile(pattern + r"$") for pattern in family["exclude"]]

    declarations: List[Tuple[dict, str]] = []
    typedefs: Dict[str, str] = {}
    walk(root, LocationTracker(), declarations, typedefs)
    del root

    by_name: Dict[str, List[Tuple[dict, str]]] = {}
    for node, file in declarations:
        if node.get("isImplicit") or not node.get("name"):
            continue
        by_name.setdefault(node["name"], []).append((node, file))

    entries: Dict[str, dict] = {}
    rejected_symbols = set()
    for c_name, group in by_name.items():
        def relative(path: str) -> Optional[str]:
            for prefix in (sdk_prefix, sdk_alias):
                if path.startswith(prefix):
                    return path[len(prefix):]
            return None

        files = [relative(file) for _, file in group]
        if not any(rel and any(p.match(rel) for p in allowed) and not any(p.match(rel) for p in excluded)
                   for rel in files):
            continue
        source_headers = sorted(set(f for f in files if f))
        def reject(reason: str) -> None:
            rejections.append({"name": c_name, "family": family["name"],
                               "headers": source_headers, "reason": reason})
        # A body (static inline helper) or internal linkage is not an import.
        if any(node.get("storageClass") == "static" or
               any(child.get("kind") == "CompoundStmt" for child in node.get("inner", ()) or ())
               for node, _ in group):
            reject("not-an-external-import")
            continue
        node = group[-1][0]
        mangled = node.get("mangledName") or ""
        if not mangled.startswith("_") or c_name.startswith("__builtin"):
            reject("missing-C-linkage-symbol")
            continue
        symbol = mangled[1:]
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_$]*$", symbol) or len(symbol) > 256:
            reject("invalid-symbol")
            continue
        # Conflicting redeclarations must never be selected by traversal order.
        prototypes = set()
        for declaration, _ in group:
            if declaration.get("isImplicit"):
                continue
            param_types = tuple(abi_scalar(clean_type(c.get("type", {}).get("qualType", "")), typedefs)
                                for c in declaration.get("inner", ()) or () if c.get("kind") == "ParmVarDecl")
            declared_return = return_type(declaration.get("type", {}).get("qualType", ""))
            prototypes.add((abi_scalar(declared_return, typedefs) if declared_return else None,
                            param_types, bool(declaration.get("variadic"))))
        if len(prototypes) != 1:
            reject("conflicting-redeclarations")
            continue
        if any(c.get("kind") == "UnavailableAttr" for g, _ in group for c in g.get("inner", ()) or ()):
            reject("unavailable-on-target")
            continue
        returns = return_type(node.get("type", {}).get("qualType", ""))
        returns = abi_type(returns, typedefs) if returns else None
        if not returns:
            reject("unsupported-return-ABI")
            continue
        params = []
        for index, child in enumerate(child for child in node.get("inner", ()) or ()
                                      if child.get("kind") == "ParmVarDecl"):
            spelling = clean_type(child.get("type", {}).get("qualType", ""))
            spelling = abi_type(spelling, typedefs) if spelling else None
            if not spelling or "\0" in spelling:
                params = None
                break
            params.append({"type": spelling, "name": parameter_name(child.get("name"), index)})
        if params is None or len(params) > MAX_PARAMETERS:
            reject("unsupported-parameter-ABI")
            continue
        # Prefer a redeclaration that names its parameters.
        for other, _ in group:
            other_params = [c for c in other.get("inner", ()) or () if c.get("kind") == "ParmVarDecl"]
            if len(other_params) == len(params):
                for index, child in enumerate(other_params):
                    if child.get("name") and params[index]["name"] == "arg%d" % index:
                        params[index]["name"] = parameter_name(child["name"], index)
        variadic = bool(node.get("variadic"))
        no_return = any(
            "__attribute__((noreturn))" in (g.get("type", {}).get("qualType", "")) or
            any(c.get("kind") in NORETURN_ATTRS for c in g.get("inner", ()) or ())
            for g, _ in group)
        if symbol.startswith("objc_msgSend"):
            convention = "objc-dispatch"
        elif variadic:
            convention = "c-variadic-stack"
        else:
            convention = "c"
        entry = {
            "name": symbol,
            "returns": returns,
            "params": params,
            "variadic": variadic,
            "noReturn": no_return,
            "callingConvention": convention,
            "family": family["name"],
        }
        if c_name in formats:
            kind, fmt, first = formats[c_name]
            entry["format"] = {"kind": kind, "formatIndex": fmt, "firstArgIndex": first}
        entry["headers"] = source_headers
        entry.update(annotations.get(c_name, {}))
        # Retain declared spellings separately when ABI-normalized scalar spellings differ.
        entry["sourceReturns"] = return_type(node.get("type", {}).get("qualType", ""))
        entry["abiReturns"] = abi_scalar(entry["sourceReturns"], typedefs)
        for param, child in zip(params, [c for c in node.get("inner", ()) or () if c.get("kind") == "ParmVarDecl"]):
            param["sourceType"] = clean_type(child.get("type", {}).get("qualType", ""))
            param["abiType"] = abi_scalar(param["sourceType"], typedefs)
            attrs = sorted({c["kind"].removesuffix("Attr") for c in child.get("inner", ()) or ()
                            if c.get("kind") in {"CFConsumedAttr", "NSConsumedAttr"}})
            if attrs:
                param["ownership"] = attrs
        floating_count = sum(p["abiType"] in FLOATING for p in params)
        if floating_count > 8 or len(params) - floating_count > 8:
            reject("stack-parameters-not-supported-by-catalog")
            continue
        if symbol in rejected_symbols or (symbol in entries and entries[symbol] != entry):
            reject("conflicting-symbol-declarations")
            entries.pop(symbol, None)
            rejected_symbols.add(symbol)
        else:
            entries[symbol] = entry
    return entries


def encode_pack(header: dict, entries: Iterable[dict]) -> str:
    lines = ["{"]
    for key in ("format", "formatVersion", "generator", "families"):
        lines.append("%s:%s," % (json.dumps(key), json.dumps(header[key], sort_keys=True,
                                                               separators=(",", ":"))))
    lines.append('"entries":[')
    lines.append(",\n".join(json.dumps(entry, sort_keys=True, separators=(",", ":"))
                            for entry in sorted(entries, key=lambda e: e["name"])))
    lines.append("]}")
    return "\n".join(lines) + "\n"


def generate(work_root: Optional[Path] = None) -> Tuple[str, dict]:
    sdk, sdk_name, sdk_version = sdk_identity()
    merged: Dict[str, dict] = {}
    family_counts = []
    rejected_symbols = set()
    rejections, provenance = [], {}
    scratch = work_root or macscope_work_root() / "t7-sdk.noindex"
    scratch.mkdir(parents=True, exist_ok=True)
    for family in FAMILIES:
        entries = collect_family(sdk, family, scratch, rejections, provenance)
        added = 0
        for name in sorted(entries):
            entry = entries[name]
            def shape(value):
                return (value["abiReturns"], tuple(p["abiType"] for p in value["params"]), value["variadic"])
            if name in rejected_symbols or (name in merged and shape(merged[name]) != shape(entry)):
                rejections.append({"name": name, "family": family["name"], "headers": entry["headers"],
                                   "reason": "conflicting-family-declarations"})
                merged.pop(name, None)
                rejected_symbols.add(name)
            elif name not in merged:
                merged[name] = entry
                added += 1
        family_counts.append({"name": family["name"], "includes": family["includes"],
                              "files": family["files"], "entries": added})
    for family in family_counts:
        family["entries"] = sum(e["family"] == family["name"] for e in merged.values())
    ordered = [merged[name] for name in sorted(merged)]
    header = {
        "format": FORMAT_IDENTIFIER,
        "formatVersion": FORMAT_VERSION,
        "generator": {"tool": TOOL, "sdk": sdk_name, "sdkVersion": sdk_version,
                      "provenanceManifest": "Scripts/signatures/sdk_signature_manifest.json"},
        "families": family_counts,
    }
    text = encode_pack(header, ordered)
    stats = {
        "entries": len(ordered),
        "noReturn": sum(1 for e in ordered if e["noReturn"]),
        "variadic": sum(1 for e in ordered if e["variadic"]),
        "format": sum(1 for e in ordered if "format" in e),
        "families": {f["name"]: f["entries"] for f in family_counts},
        "sdk": sdk_name,
    }
    stats["rejections"] = len(rejections)
    stats["bytes"] = len(text.encode())
    stats["spellings"] = len({e["returns"] for e in ordered} |
                             {p["type"] for e in ordered for p in e["params"]})
    manifest = {"schemaVersion": 1, "generator": header["generator"], "families": provenance,
                "statistics": stats}
    ledger = {"schemaVersion": 1, "rejections": sorted(rejections,
              key=lambda r: (r["family"], r["name"], r["reason"]))}
    (scratch / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    (scratch / "rejections.json").write_text(json.dumps(ledger, sort_keys=True, indent=2) + "\n")
    return text, stats


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--work-root", type=Path, default=macscope_work_root() / "t7-sdk.noindex")
    parser.add_argument("--check", action="store_true",
                        help="regenerate and diff against --output; exit 1 on drift")
    arguments = parser.parse_args(argv)
    if arguments.check:
        os.environ["MACSCOPE_SDK_REQUIRE_RETAINED_AST"] = "1"
    started = time.monotonic()
    text, stats = generate(arguments.work_root)
    elapsed = time.monotonic() - started
    summary = "%s entries (noReturn %d, variadic %d, format %d) from %s in %.1fs; families %s" % (
        stats["entries"], stats["noReturn"], stats["variadic"], stats["format"], stats["sdk"],
        elapsed, json.dumps(stats["families"], sort_keys=True))
    if arguments.check:
        try:
            committed = arguments.output.read_text(encoding="utf-8")
        except OSError as error:
            print("check: cannot read %s: %s" % (arguments.output, error), file=sys.stderr)
            return 1
        if committed != text:
            diff = difflib.unified_diff(committed.splitlines(), text.splitlines(),
                                        "committed", "regenerated", lineterm="", n=0)
            for index, line in enumerate(diff):
                if index >= 40:
                    print("...", file=sys.stderr)
                    break
                print(line, file=sys.stderr)
            print("check: %s is stale for the active SDK (%s)" % (arguments.output, stats["sdk"]),
                  file=sys.stderr)
            return 1
        print("check: up to date; " + summary)
        return 0
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_name(arguments.output.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(str(temporary), str(arguments.output))
    for source, target in [("manifest.json", "sdk_signature_manifest.json"),
                           ("rejections.json", "sdk_signature_rejections.json")]:
        (Path(__file__).parent / target).write_bytes((arguments.work_root / source).read_bytes())
    print("wrote %s: %s" % (arguments.output, summary))
    print(json.dumps(stats, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
