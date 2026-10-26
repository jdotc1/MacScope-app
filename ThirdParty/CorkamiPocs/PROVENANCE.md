# corkami/pocs PE specimens provenance and patch ledger

- Upstream: https://github.com/corkami/pocs at commit `6d277c83efdceb6916ee8c6efe6ff0639cc6193f`.
- Terms: the repository has no LICENSE file. `PE/readme.txt` (retained here unmodified) states
  "BSD Licence, 2009-2013" for the PE corpus; the terms are recorded per file in
  `Scripts/parser-oracles/oracles.lock.json`.
- Files (byte-identical to upstream; Git blob identity verified by `Scripts/tests/test_parser_oracles.py`):
  `PE/bin/normal.exe` 1499c5a8, `PE/bin/normal64.exe` 540df69f, `PE/bin/tiny.exe` acf7f576,
  `PE/bin/nosectionW7.exe` 8d527b33, `PE/readme.txt` cce2b3f9.
- Use: inert parser specimens for the RX-03 oracle goldens. They are Windows executables, committed
  without execute permission, and are never executed, loaded or mapped on any platform.
- Patches: none.
