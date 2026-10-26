# RECON-R1-T10C adjudication tooling

This standard-library-only tool verifies the standalone T10A return, binds its findings to exact
current Task 10 source bytes, selects a deterministic removal-sensitive vector subset, qualifies
24 fail-closed mutations, and emits the T10C receipt bundle.

It never imports the oracle into MacScope and never treats installed-only vectors as CoreTests
proof. Run `python3 Scripts/reconstruction_task10_adjudication/cli.py --help` for commands.
