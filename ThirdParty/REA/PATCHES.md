# REA patch ledger

Pinned upstream files remain verbatim canonical Git blobs. No upstream patches are applied. MacScope adapters under adapters/ provide bounded captured-input views, fixed operations, cooperative cancellation and owned wire DTOs. InterfaceBuilderAnalysis.ts is retained as reference only. The generated resource uses the governed runtime dependency closure and retains its license notices.

PR #261 review fixes (2026-10-12): the MacScope kernel adapter limits diagnostic
messages to 1,024 UTF-8 bytes on Unicode scalar boundaries, replacing unpaired
surrogates and preserving error classification from the complete diagnostic.
The UI adapter records bounded catalog omissions as partial coverage. These are
owned-adapter changes; pinned upstream and dependency source bytes are unchanged.
