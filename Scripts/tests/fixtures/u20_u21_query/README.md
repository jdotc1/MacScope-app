# U20/U21 query fixtures

These fixtures cover contract and recipe behaviour only. They are not evidence of MacScope's native extraction accuracy or of retrieval quality.

## `synthetic.*`

Hand-specified fixtures, not extracted from any binary.

- **`synthetic.facts.json`** follows the `u20_u21_query.research_facts/1` shape that `facts.py` writes.
- **`synthetic.type-atlas.json`** follows the JSON shape of MacScope's `list-image-types` result, as `WorkspaceScriptingAPI.typeAtlasEntryValue` encodes it. The current export's field set is used, so the omitted additive fields stay omitted.

They exercise these cases:
- the same selector in several classes and on both dispatch sides;
- one implementation shared by two methods;
- a category IMP outside any known function, and a protocol requirement without an IMP;
- a selector load with no dispatch, and a dispatch with no selector provenance;
- a class-object receiver, and a selector-stub send;
- a PAC modifier that holds a code address;
- partial decoding coverage, and an import thunk;
- Swift positional labels;
- a Swift conformance without witness methods;
- an unsupported row kind and a user-authored row.

## `libw.*`

A real public Objective-C Mach-O, built from `libw.m` in this directory. It is the only realistic Objective-C shape these fixtures contain.

Build command (zig 0.17.0 from PyPI; no SDK):

```sh
python -m ziglang cc -target aarch64-macos -O2 -shared libw.m -o libw.dylib -Wl,-undefined,dynamic_lookup
```

The dylib SHA-256 was `39baefbc6340d5c9e334df4b7b1790cfd51f77cc475e8bc7e1d47068dd7464ff`, recorded when the fixture was made. The binary is not committed. This toolchain cannot emit `objc_msgSend$sel` selector stubs: `-fobjc-msgsend-selector-stubs` is rejected. So stub dispatch appears only in the synthetic fixture.

- **`libw.facts.json`** is `facts.py` output for that dylib.
- **`libw.type-atlas.json`** was written by hand from `llvm-objdump --macho --objc-meta-data` and the `__objc_selrefs`/`__objc_classrefs` contents:
  - the slot at 0x83b0 holds `close`, and the slot at 0x83b8 holds `render:`;
  - each selector user is the completing `ldr`, as MacScope's `DataCrossReferenceResolver` records it.

  It is not MacScope output.
