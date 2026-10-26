# RecoveryKit

Local Swift transport and evidence library supplied with the SwiftRecover implementation package.
The library sources are preserved; the package manifest exposes only the library on macOS 27.
No executable target, external package dependency, worker launch, or second coordinator is installed.

The host adapter is `MacScope/Services/SwiftMetadata/RecoveryReportAdmission.swift`. It uses the
existing native admission token and reconstruction image coordinate. The caller owns scheduling,
artifact receipt admission, cancellation, and the navigator fact store. Image replacement and
publication are serialized on the main actor. The package coordinator is not instantiated by
the adapter.

Admission sequence:

1. Capture the host artifact occurrence, image slot, binary owner, analysis fingerprint and
   verified selected-slice receipt. The loaded-image initializer refuses unavailable integrity.
2. Create an immutable bundle from captured file bytes and its manifest. Verify exact membership
   and file digests once; retain that value for later admission instead of reopening the bundle.
3. Decode the expected report schema and require the exact image key and artifact/slice fields.
4. Require the current host generation and image coordinate. Reject duplicate task IDs.
5. Validate source facts and dependencies, map supported meanings, and stage a host store update.
   Publish only after all checks succeed. Imported rule identity is
   `macscope.swift-recovery-import` version `1`.
6. Present admitted live-fact counts, unresolved records and producer-reported source-validation
   status separately with `RecoveryImportSummaryView`.

Version 1 maps type/field `name` to `hasName` and type `kind` to `nominalKind`. Other meanings
remain unresolved; the adapter does not reinterpret a demangler tree as a type or source proof.
Existing metadata parsing and native decompilation remain their own producers. Imported facts
are scoped to host image occurrences even when bytes and virtual addresses are identical.
Derived facts use the existing store's dependency and revocation behavior. The adapter does not
add a persistence schema, menu action or automatic workspace import; its boundary and view are
available for host composition. No target code is executed by the import.

Focused host coverage is in `RecoveryReportAdmissionTests`: eight workorder rejection gates plus
positive admission, dependency ordering, unsupported facts, signed arm64e subtypes, superseded
task identities and changed proof lineage. Source presence does not establish build or runtime
acceptance; execution receipts are maintained separately.
