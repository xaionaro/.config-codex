# Owned-command launcher checks

Run `go test -v -timeout=90s .` here. Set `OWNED_COMMAND_TEST_LAUNCHER` to an absolute launcher path for baseline comparisons. The default selects `../../bin/owned-command` from this module.

These blackbox checks create disposable source modules and caches. They never compile the canonical guard, copy its source, install binaries, or change running guards. Real Go compilation proves native target/module/flags/internal linker policy and caller environment, cwd, arguments, stdin/stdout/stderr, relative receipt and status 125. Compiler doubles isolate cache content identity, compiler identity, retained effective settings, error cleanup, observed source mutation, serialized builders and lock release before child lifetime.

An isolated HOME fixture also checks the default `~/.codex/tools/owned-command` owner from an unrelated cwd without `OWNED_COMMAND_SOURCE` or an application checkout. Other fixtures retain explicit source overrides.

Resolver controls cover cold/warm selection without child execution, compiler stdout isolation, retained old versions after source changes, spaces and CR/LF serialization limits, failed preparation with no returned path, concurrent single-build publication and lock release. A real prepared native executable preserves the direct caller's environment/cwd/streams/arguments/status without a compiler in PATH.

The module intentionally uses only the standard library: subprocess and filesystem assertions need no external dependency, and independent checks remain runnable without fetching modules. FIFO barriers observe compiler and child boundaries without timing sleeps. Subprocess deadlines bound failures; `go test -timeout` also bounds a broken barrier.

Additional controls compare native ISA build metadata with the local compiler's clean defaults; distinguish compiler bytes, compiler root/path, version, and requested toolchain selection; and preserve final GOENV absent/empty/off states and statuses 0, 37, and 125. The selected compiler root overrides inherited GOROOT for defaults/build calls while the final child retains its original value. Fixtures isolate the user's persisted Go configuration.

This suite validates the Codex launcher boundary. Generated fixture programs are not the canonical owned-command guard; these checks do not replace guard deadline, descendant cleanup, or identity-bound cancellation E2E evidence.
