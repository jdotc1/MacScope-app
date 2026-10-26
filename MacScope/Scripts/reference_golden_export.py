# Clean-room reference-disassembler -> GoldenOutput exporter.
#
# Runs INSIDE a GUI disassembler's Python console (Document/Segment/Procedure are pre-injected
# globals) and dumps the loaded binary's analysis into MacScope's GoldenOutput JSON schema, so
# GoldenDifferentialTests can diff MacScope's output against the reference. This is OUR code written
# from the tool's documented Python API -- no third-party code is copied, and the produced
# reference.json is an authorized reference output that is NEVER committed (clean-room). See
# GoldenFixtures/README.md for the capture recipe.
#
# Address format matches GoldenOutput's `hexAddress`: "0x" + 16-digit zero-padded lowercase hex.
#
# v1 SCOPE: binary(partial), sections(partial), symbols, instructions(bounded), procedures,
# basicBlocks, pseudocode(bounded). NOT YET captured (emitted empty -> they show as
# only-in-MacScope, an EXPECTED artifact, not a parity gap): imports, exports, controlFlowEdges,
# crossReferences, demangledNames, and full binary metadata. The alternate reference exporter is intentionally
# richer now; this tool's Python API path used here lacks typed CFG/xref/import export, so this
# asymmetry is expected. Section sizes are best-effort (the Segment API exposes no end/length
# here).
import json, os

def addr(a):
    try:
        return "0x" + format(int(a) & 0xFFFFFFFFFFFFFFFF, "016x")
    except Exception:
        return "0x0000000000000000"

log = []
def cap(label, fn):
    try:
        return fn()
    except Exception as e:
        log.append("%s: %s" % (label, e))
        return None

doc = Document.getCurrentDocument()  # noqa: F821  (pre-injected by the disassembler)

out = {
    "schemaVersion": 1,
    "binary": {}, "sections": [], "symbols": [], "imports": [], "exports": [],
    "instructions": [], "procedures": [], "basicBlocks": [], "controlFlowEdges": [],
    "crossReferences": [], "demangledNames": [], "pseudocode": [],
}

path = cap("path", lambda: doc.getExecutableFilePath()) or "?"
out["binary"] = {
    "name": os.path.basename(path), "pathBasename": os.path.basename(path),
    "kind": "executable", "architecture": "arm64" if cap("is64", lambda: doc.is64Bits()) else "unknown",
    "hasEmbeddedUUID": False, "platformName": None, "minimumOSVersion": None,
    "sdkVersion": None, "buildTools": [],
}

MAX_INSTR = 8000
instr_emitted = 0
segcount = cap("segcount", lambda: doc.getSegmentCount()) or 0

for si in range(segcount):
    seg = cap("getSegment", lambda: doc.getSegment(si))
    if seg is None:
        continue
    sstart = cap("segStart", lambda: seg.getStartingAddress()) or 0
    slen = cap("segLen", lambda: seg.getLength()) or 0
    out["sections"].append({
        "name": cap("segName", lambda: seg.getName()) or "?", "address": addr(sstart),
        "size": max(0, int(slen)), "fileOffset": 0, "isExecutable": False, "isZeroFill": False,
    })

    for a in (cap("namedAddrs", lambda: seg.getNamedAddresses()) or []):
        nm = cap("nameAt", lambda: seg.getNameAtAddress(a))
        if nm:
            out["symbols"].append({"name": nm, "address": addr(a), "kind": "symbol", "libraryName": None})

    for pi in range(cap("procCount", lambda: seg.getProcedureCount()) or 0):
        proc = cap("procAt", lambda: seg.getProcedureAtIndex(pi))
        if proc is None:
            continue
        ep = cap("procEntry", lambda: proc.getEntryPoint())
        if ep is None:
            continue
        pname = cap("procName", lambda: seg.getNameAtAddress(ep)) or ("sub_%x" % int(ep))
        proc_end = ep
        for bi in range(cap("bbCount", lambda: proc.getBasicBlockCount()) or 0):
            bb = cap("bbAt", lambda: proc.getBasicBlock(bi))
            if bb is None:
                continue
            bs = int(cap("bbStart", lambda: bb.getStartingAddress()) or 0)
            be = int(cap("bbEnd", lambda: bb.getEndingAddress()) or 0)
            proc_end = max(proc_end, be)
            icount = 0
            a = bs
            while a < be:
                ins = cap("insAt", lambda: seg.getInstructionAtAddress(a))
                if ins is None:
                    break
                ilen = int(cap("insLen", lambda: ins.getInstructionLength()) or 4)
                icount += 1
                if instr_emitted < MAX_INSTR:
                    argc = cap("argc", lambda: ins.getArgumentCount()) or 0
                    ops = [r for r in (cap("rawArg", lambda: ins.getRawArgument(ai)) for ai in range(argc)) if r is not None]
                    raw = cap("readBytes", lambda: seg.readBytes(a, ilen))
                    try:
                        bytestr = " ".join("%02x" % (b if isinstance(b, int) else ord(b)) for b in raw) if raw else ""
                    except Exception:
                        bytestr = ""
                    out["instructions"].append({
                        "address": addr(a), "bytes": bytestr,
                        "mnemonic": cap("insStr", lambda: ins.getInstructionString()) or "?",
                        "operands": ", ".join(ops), "comment": None,
                    })
                    instr_emitted += 1
                if ilen <= 0:
                    break
                a += ilen
            out["basicBlocks"].append({
                "procedureStartAddress": addr(ep), "startAddress": addr(bs),
                "endAddress": addr(be), "instructionCount": icount,
            })
        out["procedures"].append({
            "name": pname, "startAddress": addr(ep), "endAddress": addr(proc_end), "confidence": 1.0,
        })
        if len(out["pseudocode"]) < 8:
            pc = cap("decompile", lambda: proc.decompile())
            if pc:
                out["pseudocode"].append({
                    "procedureStartAddress": addr(ep), "procedureName": pname,
                    "returnType": "", "lines": str(pc).split("\n"),
                })

dst = os.path.expanduser("~/reference_golden.json")
with open(dst, "w") as f:
    json.dump(out, f, indent=2)
print("REFERENCE_EXPORT_DONE -> %s  counts=%s  log=%s" % (
    dst, {k: len(v) for k, v in out.items() if isinstance(v, list)}, log[:8]))
