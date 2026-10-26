# libjpeg-turbo header fixtures

Unmodified public headers and license from libjpeg-turbo 3.2.0, upstream commit
`c85e6b905bf237038faa936dab160ebfc5da0344`.

`public-layout.c` retains the LP64 `size_t`, opaque `FILE`,
`JCONFIG_INCLUDED=1`, and `JPEG_LIB_VERSION=80` configuration. It includes only
public `jpeglib.h` and `jmorecfg.h`; no `jpegint.h` declarations are imported.
The focused test preprocesses this fixture with Clang (`-E -P -x c`) before
passing it to the bounded C header parser. This is explicit test configuration,
not a new preprocessor or implicit macro authority in the application.

`jpegint.h` is an unmodified libjpeg-turbo 3.2.0 internal header from the same
upstream commit.
The existing `LICENSE.md` describes the applicable upstream licenses, including
the IJG license referenced by the header. The source's copyright and license
notices are retained.

The witness helper preprocesses `public-layout.c` followed by `jpegint.h`,
then imports the resulting declarations through
`WorkspaceStore.defineTypesFromCHeader`, the same path used by header import.
This preserves the public fixture's explicit LP64/ABI8 configuration while adding
internal declarations only to the opt-in witness. Its receipt lists `jpeglib.h`,
`jmorecfg.h`, and `jpegint.h` plus import counts and diagnostics. The fixture-only
header-loading test uses synthetic exports and never opens the libjpeg dylib.

## Full-declaration headers (8-bit target context)

Additional unmodified files from libjpeg-turbo 3.2.0, upstream commit
`c85e6b905bf237038faa936dab160ebfc5da0344`:

- `src/jdct.h`, `src/jmemsys.h`, `src/jdhuff.h`, `src/jchuff.h`
- `simd/jsimdint.h`, `simd/jsimd.h`, `simd/jsimddct.h`
- Include dependencies: `src/jinclude.h`, `src/jsamplecomp.h`, `simd/jsimdconst.h`

The existing three flat headers are unchanged. The added files retain their
upstream relative layout so the SIMD headers' `../src/` includes resolve.
`MACSCOPE_LIBJPEG_HEADER_SET=full` selects this additional declaration set;
an unset selector keeps the original three-header environment.

`fixture-target-config.h` is hand-written fixture configuration, not an upstream
file and not generated from a template. Its ARM64/LP64, SIMD, 8-bit precision,
and JPEG ABI8 values describe the scored target. Its comments cite each use.
`src/jconfigint.h` is a fixture configuration shim containing only an include of
that file. After this configuration and `public-layout.c` supply size_t, opaque
FILE and configuration macros, the prelude defines `__JINCLUDE_H__` to keep
system stdio, stdlib and string declarations out of the import environment.

This context does not load precision-12 DCT declarations. Their 20 truth rows
remain uncovered with reason `precision_12_context_not_loaded`; the ceiling is
269 of 289 GLOBAL/EXTERN truth rows before importer refusals. Other-architecture
SIMD declarations are retained; parsed prototype totals are not truth coverage.
