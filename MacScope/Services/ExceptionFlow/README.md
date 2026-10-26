# Exception-flow evidence

`ExceptionFlowService.analyze(binary:)` is the on-demand native engine entry over
an admitted `LoadedBinary`. The loader supplies linked-file type and complete
active-encryption ranges. The service reuses the compact-unwind reader and the
dedicated exception augmentation API on the existing DWARF reader. It never
reopens files, hashes bytes, dereferences an indirect pointer, or executes an image.

The report binds its model version and source spans to the existing selected-slice
identity. Each function retains its LSDA, protected intervals, landing pads,
action graph, reverse-indexed type fields, negative-specification index lists,
and CIE/FDE association. Negative-specification source spans include their zero
terminators. Malformed metadata fails atomically; no partially assembled report
escapes. Unknown encodings fail closed. Present malformed compact metadata cannot
be replaced by a same-function FDE lookup; DWARF-mode references must identify the
exact FDE boundary and agree with function, LSDA and personality-slot evidence.

Candidates are structural exception-metadata destinations. Personality and type
pointers retain direct-versus-indirect identity, with indirect slots unresolved.
The report makes no runtime reachability, catch matching, personality identity,
PAC authentication, or ordinary Swift throws claim. No lossy classic or chained
symbol summary is promoted to exact target evidence.

The pure LSDA parser resides in AnalysisCore. Composition remains alongside the
app's unwind audit services because the existing DWARF reader belongs to
DebuggerCore, which depends on AnalysisCore. This preserves dependency direction
and the frozen worker boundary. The entry returns an immutable derived report;
this increment does not add persistence, a UI panel, or an MCP command.

Limits are explicit: 1 MiB per LSDA, 8 MiB aggregate LSDA input, 4096 associations,
2 MiB each compact/CFI section, 16384 compact rows, and bounded parser records and
operations. Unsupported unwind modes, encrypted metadata, ambiguous mappings,
indirect LSDA addresses, and inconsistent associations refuse. The compiler
fixture source and receipt are under `Scripts/parser-oracles/exception-flow`.
