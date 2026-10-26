# EntitlementDiff source adaptations and patches

Donor: `https://github.com/jdotc1/EntitlementDiff`, immutable commit
`a28a431895a65fe6d23494038ef67f62e80bd559`. The complete upstream `LICENSE` is
retained verbatim beside this ledger. Copyright (c) 2026 EntitlementDiff
contributors; MIT License.

## Selected source origins

The bounded source adaptation uses these donor paths:

- `Sources/EntitlementDiffCore/EntitlementValue.swift`
- `Sources/EntitlementDiffCore/EntitlementSnapshot.swift`
- `Sources/EntitlementDiffCore/EntitlementComparison.swift`
- `Sources/EntitlementDiffCore/FoundationEntitlementDecoder.swift`
- `Sources/EntitlementDiffCore/DisplayText.swift`
- `Sources/EntitlementDiffModel/ComparisonBrowser.swift`
- `Sources/EntitlementDiffModel/ComparisonModel.swift`
- `Sources/EntitlementDiffModel/BrowserRecoveryGuidance.swift`
- `Sources/EntitlementDiffApp/Views/ChangeTable.swift`
- `Sources/EntitlementDiffApp/Views/ContentView.swift`

Core value and browser-projection source is ported under
`MacScope/Services/EntitlementComparison/`, with donor module imports removed
because these files compile together in `MacScopeApp`. MacScope's adapted
snapshot and comparison session replace the donor input lifecycle with loaded
image slots, explicit architecture, extraction provenance and source-generation
guards. The adapted snapshot omits signing identifiers and host-default
architecture selection. The existing entitlement risk reader remains unchanged.

The donor table columns and browser controls inform
`MacScope/Features/MachOMetadata/EntitlementComparisonView.swift`, within the
existing metadata surface. MacScope supplies its own slot controls and styling.
The donor app actions, Security extraction, saved reports, inspector, and focused
string/data views are not included. No donor package manifest or external
package dependency is imported.

## Reproduce and build offline

Read each listed source from the exact donor revision with
`git show a28a431895a65fe6d23494038ef67f62e80bd559:<path>`. Apply the checked-in
MacScope adaptations described above and retain the full MIT copyright,
permission, and disclaimer in every ported file header. The repository-owned
Swift sources are the build inputs; there is no generated dependency artifact,
download, or runtime materializer. Existing project source groups compile the
adapted sources directly into `MacScopeApp` during the normal focused Debug
development build. Adapted types, exact decoding, state handling, slot identity,
publication invalidation and browser selection continuity have focused MacScope
test coverage; execution evidence belongs to the accompanying development
record, rather than this source-origin ledger.

## Rollback

Remove the comparison surface and its source folder together with this component's
inventory entry, notice and policy row. Preserve the existing image-loading
mechanism, entitlement reader and risk consumers. This integration adds no
persistent workspace record or schema migration and changes no dependency cache.
