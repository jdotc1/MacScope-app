# Repository and distribution license decision gate

Status: **unresolved for public distribution**

Effective record date: **2026-07-20**

First-party source license selected: **MIT (2026-11-02)**

The original first-party MacScope source code, documentation, and project-owned
assets are licensed under the MIT License in the repository-root `LICENSE`
file, except where another license or copyright notice applies. This
2026-11-02 first-party licensing decision does not relicense third-party
material. Although this repository already publishes a source snapshot,
approval of the complete dependency-bearing source closure or official
application binaries remains unresolved.

Dependency-bearing local development follows
`MacScope/PARITY_CONTRACT.md` when every component is pinned, governed, and
used within its approved architecture. Public distribution remains blocked
until the repository owner records a separate decision covering at least:

- the scope and exceptions of the selected first-party MIT license;
- source-versus-binary distribution scope;
- all linked, embedded, copied, and generated components;
- transitive license and notice obligations;
- source-offer, attribution, relinking, or file-level obligations where
  applicable;
- generated processor specifications, data packs, and bundled resources;
- Developer ID signing, notarization, packaging, and notice presentation;
- a legal review appropriate to the intended distribution.

The dependency validator must fail when the manifest claims public-distribution
approval while this decision remains unresolved. Changing this status requires
an explicit repository-owner decision and synchronized updates to this file,
`THIRD_PARTY_COMPONENTS.yml`, `THIRD_PARTY_NOTICES.md`, and the
capability contract.
