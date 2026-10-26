"""Execute one explicitly selected frozen Gate F command in a persisted run."""
import argparse
from pathlib import Path
import signal
import sys
import threading

from .operator_run import load_run


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-root", required=True, type=Path)
    parser.add_argument("--run-manifest", default="run.json")
    parser.add_argument("--command-id", required=True)
    parser.add_argument("--scenario-id", required=True)
    args = parser.parse_args(argv)
    cancellation = threading.Event()
    previous = {}
    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.signal(number, lambda *_: cancellation.set())
        run = load_run(args.run_root, args.run_manifest)
        receipt = run.execute(args.command_id, args.scenario_id, cancellation)
        print("Gate F command receipt: " + receipt["canonical_sha256"])
        return 0
    except (OSError, ValueError) as error:
        print("Gate F command failed; retained evidence is not acceptance: " + str(error), file=sys.stderr)
        return 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
