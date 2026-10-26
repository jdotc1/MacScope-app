# Static IPC inventory fixture

`build.sh` creates a small arm64 app bundle in `Fixture.app` and signs its binaries ad hoc. It is a compile-only detection fixture and is never installed, launched, or registered with launchd. The helper's embedded Info.plist contains `SMAuthorizedClients`; the host Info.plist contains `SMPrivilegedExecutables`. These requirement strings exercise plist parsing only. Ad-hoc signing does not establish SMJobBless acceptance or installation.

The fixture includes a named NSXPC helper listener, a three-method protocol with one reply block, an XPC service bundle, a libxpc listener and constant dictionary key, a declaration with no listener, an anonymous listener, a LaunchDaemon and LaunchAgent declaration, and a login item bundle. The `Fixture.app` output is checked in so tests do not compile or sign during their run. Rebuild only when the fixture sources or script change; the Mach-O UUID and signature bytes may differ across builds.
