# LLDB `thread list` / `thread backtrace` transcripts

Real output from Xcode 27.2 LLDB (`/Applications/Xcode-beta.app/.../usr/bin/lldb --batch`),
captured 2026-10-12 against a two-thread C sample (main stopped at a breakpoint in
`parse_header`, a worker thread sleeping). Backs `DebuggerThreadListParserFixtureTests`.

- `production-format-stopped-refresh.txt`: the `thread list` then `thread backtrace` output
  under the `thread-format` / `thread-stop-format` settings that
  `DebuggerLLDBSealedLaunchPlan.makeSemanticCommands` installs (colon headers, `tid = …`,
  no queue). This is what `PersistentLLDBProductionController.stoppedRefreshCommands` reads.
- `default-format-thread-list.txt`: `thread list` under LLDB's default thread format.
- `production-format-four-thread-selected-non-stop-thread.txt`: the complete production stopped
  refresh (`thread list`, `thread backtrace`, `register read`, `memory read $sp`) captured
  2026-10-13 through the persistent adapter against `Fixtures/DebuggerThreadsLiveFixture.c`
  (main plus three workers, breakpoint stop on thread #4 at `rendezvous`) after `thread select 1`.
  The selected thread (#1, `__ulock_wait`) is not the stop thread; backs the lane AQ
  selection-mapping test.
- `production-format-named-threads.txt`: `thread list` then `thread backtrace` captured 2026-10-13
  (Xcode 27.2 LLDB, `--batch`, 0.68 s end to end) against `Fixtures/DebuggerThreadsLiveFixture.c`
  under the thread format that adds `{ ${module.file.basename}`${function.name}}` and
  `{, name = '${thread.name}'}`. Every thread carries its top frame's module`function, and the
  workers carry their pthread names. A gdb-remote packet log of the same run had no
  `jThreadExtendedInfo` or `qThreadExtraInfo` request.
