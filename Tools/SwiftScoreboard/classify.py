"""Independent spelling and mangling classifiers for Swift function symbols.

The classifiers describe symbol roles, not function semantics. Mangled matching
uses the terminal productions in SwiftDemangler.swift; no subprocess or demangled
spelling is used by that classifier.
"""

import re


VALUE_WITNESSES = {
    "wxx": "destroy",
    "wcp": "initializeWithCopy",
    "wca": "assignWithCopy",
    "wta": "assignWithTake",
    "wtk": "initializeWithTake",
    "wCP": "initializeBufferWithCopyOfBuffer",
    "wet": "getEnumTagSinglePayload",
    "wst": "storeEnumTagSinglePayload",
    "wug": "getEnumTag",
    "wup": "destructiveProjectEnumData",
    "wui": "destructiveInjectEnumTag",
}


def is_swift_mangled(name):
    """Recognise Swift ABI prefixes, including the Mach-O underscore."""
    return name.startswith(("$s", "$S", "_$s", "_$S", "_T"))


def _result(kind, merged=False, specialised=False, role=None):
    result = {"class": kind, "merged": merged, "specialised": specialised}
    if role is not None:
        result["role"] = role
    return result


def _non_swift(name):
    for prefix, kind in (
        ("___swift_closure_destructor", "closureContextDestructor"),
        ("___swift__destructor", "boxDestructor"),
        ("___swift_exist", "existentialDestructor"),
        ("___swift_memcpy", "sharedHelper"),
        ("___swift_noop_void_return", "sharedHelper"),
        ("___swift_instantiateConcrete", "sharedHelper"),
        ("_get_witness_table", "sharedHelper"),
        ("_block_copy_helper", "blockHelper"),
        ("_block_destroy_helper", "blockHelper"),
        ("___copy_helper_block", "blockHelper"),
        ("___destroy_helper_block", "blockHelper"),
    ):
        if name.startswith(prefix):
            return _result(kind)
    if name == "_main":
        return _result("main")
    if name.startswith(("-[", "+[")):
        return _result("objcMethod")
    return _result("other")


def _strip_specialization(name):
    """Remove a leading specialization with nested angle brackets intact."""
    if name.startswith("specialized "):
        return name[len("specialized "):]
    for prefix in ("generic specialization <", "function signature specialization <"):
        if not name.startswith(prefix):
            continue
        depth = 1
        for index in range(len(prefix), len(name)):
            if name[index] == "<":
                depth += 1
            elif name[index] == ">" and name[index - 1] != "-":
                depth -= 1
                if depth == 0 and name[index + 1:index + 5] == " of ":
                    return name[index + 5:]
    return None


def classify_demangled(name, raw_name=None):
    """Classify a compact demangled spelling, preserving wrapper flags.

    Supplying raw_name makes the Swift/non-Swift boundary exact, including a
    mangled symbol which the installed demangler echoes unchanged.
    """
    if raw_name is not None and not is_swift_mangled(raw_name):
        return _non_swift(raw_name)
    if raw_name is None:
        native = _non_swift(name)
        if native["class"] == "other":
            native = _non_swift("_" + name)
        if native["class"] != "other":
            return native
    merged = specialised = False
    while True:
        if name.startswith("merged "):
            merged = True
            name = name[len("merged "):]
            continue
        inner = _strip_specialization(name)
        if inner is not None:
            specialised = True
            name = inner
            continue
        break
    kind = None
    role = None
    for prefix, candidate in (
        ("type metadata accessor for ", "metadataAccessor"),
        ("type metadata instantiation function for ", "metadataInstantiation"),
        ("type metadata completion function for ", "metadataCompletion"),
    ):
        if name.startswith(prefix):
            kind = candidate
            break
    if kind is None:
        for candidate_role in VALUE_WITNESSES.values():
            if name.startswith(candidate_role + " value witness for "):
                kind, role = "valueWitness", candidate_role
                break
    if kind is None:
        for prefix, candidate in (
            ("protocol witness for ", "protocolWitness"),
            ("lazy protocol witness table accessor for ", "witnessTableAccessor"),
            ("partial apply forwarder for ", "partialApply"),
            ("one-time initialization function for ", "onceInit"),
            ("key path getter for ", "keyPath"),
            ("key path setter for ", "keyPath"),
            ("@objc ", "objcThunk"),
            ("outlined copy of ", "outlined"),
            ("outlined consume of ", "outlined"),
            ("outlined destroy of ", "outlined"),
            ("outlined init with copy of ", "outlined"),
            ("outlined assign with take of ", "outlined"),
            ("outlined retain of ", "outlined"),
            ("outlined release of ", "outlined"),
            ("outlined bridged method", "outlined"),
        ):
            if name.startswith(prefix):
                kind = candidate
                break
    if kind is None and re.match(r"\(\d+\) (?:await|suspend) resume partial function for ", name):
        kind = "asyncPartial"
    if kind is None and name.startswith("reabstraction thunk helper"):
        kind = "reabstraction"
    if kind is None and re.search(r"closure #\d+.*? in ", name):
        kind = "closure"
    if kind is None and name.startswith("variable initialization expression of "):
        kind = "varInit"
    if kind is None and re.match(r"default argument \d+ of ", name):
        kind = "defaultArg"
    if kind is None and re.search(r"\.(?:getter|setter|modify|read|unsafeMutableAddressor) : .+$", name):
        kind = "accessor"
    if kind is None and any(part in name for part in (
        "__allocating_init", "__deallocating_deinit", ".deinit", ".init("
    )):
        kind = "initDeinit"
    if kind is None:
        if raw_name is not None or "." in name or " -> " in name or merged or specialised:
            kind = "function"
        else:
            return _non_swift(name)
    return _result(kind, merged, specialised, role)


def _mangled_role(body, specialized=False):
    """Read terminal roles, or roles preceding specialization type operands."""
    suffixes = (
        (r"Ma", "metadataAccessor"),
        (r"Mi", "metadataInstantiation"),
        (r"Mr", "metadataCompletion"),
        (r"TW", "protocolWitness"),
        (r"Wl", "witnessTableAccessor"),
        (r"TA", "partialApply"),
        (r"WZ", "onceInit"),
        (r"T[Kk]", "keyPath"),
        (r"To", "objcThunk"),
        (r"WO[yhecdrs]|Te[opam][nbg]*_", "outlined"),
        (r"T[QY]\d+_", "asyncPartial"),
        (r"TR", "reabstraction"),
        (r"fU\d*_", "closure"),
        (r"fi", "varInit"),
        (r"fA\d*_", "defaultArg"),
        (r"(?:[vi][gsMr]|vau)Z?", "accessor"),
        (r"f[CDdc]Z?", "initDeinit"),
    )
    # Without specialization, only a terminal production is a role. Generic
    # specialization appends type operands to the original entity; select its
    # last entity production, including ordinary F, after hiding identifiers.
    # Otherwise TR inside a generic conformance constraint can be mistaken for
    # a reabstraction helper even though a later F terminates the function.
    end = "" if specialized else "$"
    if specialized:
        # Hide length-prefixed identifiers before inspecting internal terminals:
        # a type argument named "Map" is not a metadata accessor (Ma).
        chars = list(body)
        cursor = 0
        while cursor < len(body):
            if not body[cursor].isdigit():
                cursor += 1
                continue
            finish = cursor
            while finish < len(body) and body[finish].isdigit():
                finish += 1
            length = int(body[cursor:finish])
            if 0 < length <= len(body) - finish and body[finish].isalpha():
                chars[finish:finish + length] = "." * length
                cursor = finish + length
            else:
                cursor = finish
        body = "".join(chars)
    productions = [(suffix, kind, None) for suffix, kind in suffixes[:3]]
    productions.extend((re.escape(code), "valueWitness", role) for code, role in VALUE_WITNESSES.items())
    productions.extend((suffix, kind, None) for suffix, kind in suffixes[3:])
    if specialized:
        productions.append((r"FZ?", "function", None))
        candidates = [
            (match.end(), kind, role)
            for suffix, kind, role in productions
            for match in re.finditer("(?:" + suffix + ")", body)
        ]
        if candidates:
            _, kind, role = max(candidates, key=lambda candidate: candidate[0])
            return kind, role
        return "function", None
    for suffix, kind, role in productions:
        if re.search("(?:" + suffix + ")" + end, body):
            return kind, role
    return "function", None


def classify_mangled(raw_name):
    """Classify independently from Swift terminal mangling productions."""
    if not is_swift_mangled(raw_name):
        return _non_swift(raw_name)
    body = raw_name
    merged = specialised = generic_operands = False
    while True:
        if body.endswith("Tm"):
            merged = True
            body = body[:-2]
            continue
        signatures = list(re.finditer(r"Tf\d", body))
        if signatures and re.search(r"Tf\d[^ ]*_[ndegxs]+$", body):
            specialised = True
            # Constant/closure propagation appends a length-prefixed symbol
            # operand before Tf. That operand can itself contain Tf or fU;
            # those describe the propagated argument, not this function.
            operand = re.search(
                r"(?:TR|Tg\d|FZ?|f[CDdc]|fU\d*_|v[gsMr])(?=\d+\$[sS])",
                body,
            )
            body = body[:operand.end() if operand else signatures[-1].start()]
            continue
        generic = re.search(r"T(?:tg|g)\d+$", body)
        if generic:
            specialised = generic_operands = True
            body = body[:generic.start()]
            continue
        break
    kind, role = _mangled_role(body, generic_operands)
    return _result(kind, merged, specialised, role)
