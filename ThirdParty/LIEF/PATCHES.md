# LIEF patch ledger (RX-03)

No patches: the vendored source is byte-identical to the pinned upstream revision recorded in
THIRD_PARTY_COMPONENTS.yml, pruned only by omission (tests, docs, examples, bindings and unused
bundled archives are not vendored). Built offline, once per cache key, by
Scripts/dependencies/build_parser_engines.py into the shared content-addressed dependency cache;
never compiled by an Xcode target and never acquired at build time.
