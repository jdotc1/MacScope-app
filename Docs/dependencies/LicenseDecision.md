# Repository and distribution license decision gate

Status: **unresolved for public distribution**

Effective record date: **2026-07-20**

MacScope is currently treated as a private-development project. This document
intentionally does not select a top-level repository license or authorize a
public binary/source distribution.

Dependency-bearing local development follows
`MacScope/PARITY_CONTRACT.md` when every component is pinned, governed, and
used within its approved architecture. Public distribution remains blocked
until the repository owner records a separate decision covering at least:

- the top-level MacScope source license;
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
