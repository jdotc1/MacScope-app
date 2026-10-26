# Unsigned development build

`Scripts/build_unsigned_development.sh PREPARED_CHECKOUT PREPARED_DERIVED_DATA OUTPUT_ROOT`
builds the real MacScopeApp Debug target without invoking a signing command.
The output root must be outside the checkout, under the local Developer workspace.
The shared heavy-job lock covers preparation and compilation.

This is an explicit local iteration path, not release or installed acceptance.
The supplied preparation must have matching dependency Git objects, an exact
Debug/arm64 build request for that checkout, accepted read-only cache views and
retained successful source-phase receipts. Missing or changed receipts fail;
there is no dependency producer, verification fallback, or golden-test execution.
The golden result is inherited only when its recorded native identities agree
with the admitted immutable cache records. The app gets a development record;
it does not get a fabricated release qualification record.

Project generation is an explicit development variant of the existing generator.
The authored project specification, signing identity and release configurations
remain unchanged. Every protected target requires the unsigned Debug opt-in;
Release, install/archive, CI, source qualification and nonempty signing identities
are rejected. The normal build entry point rejects the development project marker
and regenerates its ordinary certificate-backed project before use.
The development admission binds generation input metadata, the generated project,
its marker, local dependency configuration, the package symlink and sorted source
path inventory. Guards fail if those identities change. This development receipt
does not invoke the ordinary freshness recorder or hash protected payloads.

The compiler/linker's normal arm64 executable output may contain its platform
required ad hoc code directory. No codesign signing command, certificate signing,
installation, archive, notarization or publication is performed by this path.
Unsigned XPC trust/launch and debugger capabilities are not release-qualified.
Use this path for bounded native UI development, not installed durability proof.
