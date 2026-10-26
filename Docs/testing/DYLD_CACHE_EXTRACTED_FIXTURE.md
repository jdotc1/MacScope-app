# HS-5b dyld-cache extracted image fixture

One real image projected out of the macOS shared cache, used by the opt-in test
`LoaderRobustnessDiagnosticsTests.testRealSharedCacheExtractedImageIsDiagnosedNotMisread`
to exercise the HS-5 ObjC diagnosis (`objcMetadataFromSharedCacheExtraction`) on real bytes.
It lives outside the repo and outside LFS.

| Field | Value |
|---|---|
| Image | `/System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement` |
| Stored at | `MacScopeQualificationCache-20260920/fixtures/dyld-cache-extracted/ServiceManagement` |
| sha256 | `3e2e89bbc08f74b8deac04cd9086361908136bc271eaec8953c9cd64edb08b1d` |
| Size | 52,960 bytes (arm64e MH_DYLIB; 1 `__objc_classlist` entry, 39 `__objc_selrefs`) |
| Source cache | `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e` (+ `.NN` sub-caches, memory-mapped, not scanned) |
| macOS build | 26B5101f (`sw_vers -buildVersion`, macOS 27.2) |
| Extracted | 2026-10-12, M1 Max |

## Extraction

MacScope's own projection path (`DyldSharedCacheParser.locateImage` + `makeMultiFileReader` +
`projectImage(_:using:header:)`), the same one `DyldSharedCacheBinaryLoader` uses, compiled into a
one-off driver. Xcode's `dsc_extractor.bundle` was not used: it only extracts the whole cache.
The driver source is kept next to the fixture (`extract_one_image.swift`, plus `extract_stub.swift`,
a stand-in for `StringLiteralSummary` so `LittleEndianReader.swift` compiles alone).

```sh
M=MacScope   # repo checkout
swiftc -O -o dscproj extract_one_image.swift extract_stub.swift \
  $M/Services/Loader/DyldSharedCacheParser.swift $M/Services/Loader/DyldMultiFileCacheReader.swift \
  $M/Services/Loader/LittleEndianReader.swift $M/Models/MachOConstants.swift
./dscproj /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e \
  /System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement ServiceManagement
```

The bytes depend on the macOS build; after an OS update re-extract and update the pinned sha256/size
in the test (it fails on a digest mismatch rather than testing other bytes).

## Running the test

```sh
TEST_RUNNER_MACSCOPE_DYLD_CACHE_EXTRACTED_IMAGE=MacScopeQualificationCache-20260920/fixtures/dyld-cache-extracted/ServiceManagement \
  Scripts/dev_loop.sh CoreTests/LoaderRobustnessDiagnosticsTests
```

Without the variable the test is skipped. Expected outcome: exactly one
`objcMetadataFromSharedCacheExtraction` loader finding (the image's selector references point into
the cache's shared selector pool, outside every segment of the extracted image), surfaced by the
diagnostics collector as `objcMetadataUnavailable`.
