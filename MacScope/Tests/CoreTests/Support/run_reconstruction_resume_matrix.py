#!/usr/bin/env python3
"""T27 bounded real-SIGKILL proof; each requested point gets one kill and one relaunch.

Uses only the caller-supplied freshly built fixture host. No installed app, provider endpoint,
build, export, signing verification or provenance hashing. The standard heavy gate owns the
whole matrix; points serialize to stay within one admitted native execution slot.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / 'Scripts' / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402

POINTS = ["completedCheckpoint", "executingReads", "modelRound", "retrieveEvidence",
          "sourceReplyPublished", "sourceRevisionCommitted", "buildCompleted",
          "behaviorFailure", "repairAdmission", "repairReplyPublished"]


def run_host(app, root, point, hard_deadline):
    # The relay can stop admission between hosts without cancelling an already admitted host.
    # Each matrix has its own marker, so another run cannot inherit a stale permission signal.
    if (root.parent / "stop-new-hosts").exists():
        raise RuntimeError("native hold: no new host admitted; preserve this root for continuation")
    remaining = hard_deadline - time.time()
    if remaining < 210:
        raise RuntimeError("native hold admission cutoff: fewer than 210 seconds remain")
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith("XCTest") or key in ("XCInjectBundleInto", "DYLD_INSERT_LIBRARIES"):
            environment.pop(key)
    environment["MACSCOPE_HEADLESS_HOST"] = "1"
    process = subprocess.Popen([str(app), "--headless-reconstruction-resume-host", str(root), point],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment)
    print(json.dumps({"event": "HEADLESS START", "point": point, "pid": process.pid,
                      "root": str(root)}), flush=True)
    output = bytearray()
    ready = False
    deadline = time.monotonic() + 180
    selection = selectors.DefaultSelector()
    selection.register(process.stdout, selectors.EVENT_READ)
    try:
        while selection.get_map():
            if time.monotonic() >= deadline:
                raise TimeoutError(f"owned host {process.pid} exceeded 180 seconds")
            for key, _ in selection.select(max(0, deadline - time.monotonic())):
                data = os.read(key.fd, 65536)
                if not data:
                    selection.unregister(key.fileobj)
                    continue
                output.extend(data)
                if point != "resume" and b"T27_KILL_READY " in output and not ready:
                    arrival = json.loads((root / "kill-arrived.json").read_text())
                    if arrival != {"point": point, "pid": str(process.pid)}:
                        raise RuntimeError("arrival does not match owned process and point")
                    ready = True
                    os.kill(process.pid, signal.SIGKILL)
        returncode = process.wait(timeout=max(0.1, deadline - time.monotonic()))
        if point != "resume" and (not ready or returncode != -signal.SIGKILL):
            raise RuntimeError(f"point not reached or host not killed: {point}, exit {returncode}")
        if point == "resume" and returncode != 0:
            raise RuntimeError(f"resume host failed: exit {returncode}")
        return returncode
    finally:
        if process.poll() is None:
            # Only our Popen child, never a discovered or foreign process.
            os.kill(process.pid, signal.SIGKILL)
            process.wait(timeout=15)
        selection.close()
        (root / f"host-{point}.log").write_bytes(output)
        print(json.dumps({"event": "HEADLESS END", "point": point, "pid": process.pid,
                          "exit": process.returncode}), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--deadline", required=True)
    parser.add_argument("--points", default=",".join(POINTS))
    # Cross-point fresh-call baseline (freshSourceCalls,freshRoundCalls). The fixed fixture job
    # makes exactly 2 fresh source calls and 1 fresh regular round call when every published reply
    # is replayed (completedCheckpoint, matrix-0509). Every point, including a point run alone in
    # its own invocation, must match it; a resume that re-dispatches a published reply fails here.
    parser.add_argument("--expected-fresh-calls", default="2,1")
    args = parser.parse_args()
    expected_calls = tuple(int(value) for value in args.expected_fresh_calls.split(","))
    if len(expected_calls) != 2:
        parser.error("--expected-fresh-calls takes SOURCE,ROUND")
    points = args.points.split(",")
    if not points or any(point not in POINTS for point in points) or len(set(points)) != len(points):
        parser.error("unknown or repeated kill point")
    if not args.app.is_absolute() or not args.app.is_file() or not args.output.is_absolute():
        parser.error("absolute executable and output paths required")
    deadline = datetime.datetime.fromisoformat(args.deadline.replace("Z", "+00:00")).timestamp()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    lock = macscope_work_root() / ".macscope-heavy-gate.lock"
    fds = [os.open(str(lock), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)]
    fds.extend(os.open(str(lock) + f".slot-{slot}", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
               for slot in range(3))
    helper = args.repo / "Scripts/qualification/heavy_gate_lock.py"
    subprocess.run([sys.executable, "-B", str(helper), "acquire", "--fd", str(fds[0]), "--lock", str(lock),
                    "--pid", str(os.getpid()), "--work-root", str(args.repo), "--integration-ref", "t27-fixture-host",
                    "--mode", "headless-loopback", "--run-root", str(args.output), "--shared",
                    "--slot-fds", ",".join(str(fd) for fd in fds[1:]), "--timeout", "30"],
                   pass_fds=fds, check=True)
    receipts = []
    baseline = None
    try:
        for point in points:
            root = args.output / f"t27-resume-{point}-{uuid.uuid4().hex[:8]}"
            root.mkdir(mode=0o700)
            (root / "fixture-request.json").write_text(json.dumps({"domain": "reconstruction.resume.fixture.v1",
                "workspaceID": str(uuid.uuid4()), "projectID": str(uuid.uuid4()), "jobID": str(uuid.uuid4())}))
            started = time.monotonic()
            run_host(args.app, root, point, deadline)
            run_host(args.app, root, "resume", deadline)
            report = json.loads((root / "result.json").read_text())
            assert report["state"] == "completed" and report["packageReopened"]
            assert report["sourceRevisions"] == 2 and report["evaluations"] == 2 and report["harnessPassed"] == 37
            assert report["activationProhibited"] and report["quitIgnoredDuringExecution"] and report["quitAllowedWhenIdle"]
            assert report["liveHistoryRoundCount"] > 0 and report["completedPackageHasNoReplayProvenance"]
            counts = (report["freshSourceCalls"], report["freshRoundCalls"])
            assert counts == expected_calls, (point, "fresh model calls differ from cross-point baseline",
                                              counts, expected_calls)
            if baseline is None:
                baseline = counts
            assert counts == baseline, (point, "extra fresh model calls", counts, baseline)
            if point in ("sourceReplyPublished", "repairReplyPublished"):
                assert report["replayedReplies"] >= 1, (point, "published reply was not replayed")
                assert report["liveHistoryReplayedRoundCount"] >= 1, (point, "terminal Save lost replay history")
            if point == "modelRound":
                assert report["replayedNativePromptFacts"] > 0, (point, "no frozen native prompt facts replayed")
            if point == "sourceReplyPublished":
                assert report["activePackageMigrated"], (point, "did not resume the portable imported package")
            receipt = {"point": point, "seconds": round(time.monotonic() - started, 3), "root": str(root), "report": report}
            receipts.append(receipt)
            (args.output / "matrix.json").write_text(json.dumps(receipts, indent=2))
            print(json.dumps({"event": "POINT PASSED", **receipt}), flush=True)
    finally:
        subprocess.run([sys.executable, "-B", str(helper), "release", "--lock", str(lock), "--pid", str(os.getpid())], check=False)
        for fd in fds:
            os.close(fd)
    print(json.dumps({"event": "MATRIX PASSED", "points": len(receipts)}), flush=True)


if __name__ == "__main__":
    main()
