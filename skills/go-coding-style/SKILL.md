---
name: go-coding-style
description: Use when writing, reviewing, or modifying Go code (*.go, go.mod, go.sum files) or reviewing diffs/PRs containing Go changes — ensures code quality and adherence to the established Go conventions for naming, error handling, concurrency, types, logging, and code organization
---

# Go Coding Style

## Idiomatic Go

- Write idiomatic Go (Effective Go, Go Proverbs).
- Choose the correct, clean solution even when it's harder than the simple, practical, or convenient one.
- **Read before using.** Before first use of any package (stdlib or third-party), read its API surface — godoc, source, or context7. Don't guess signatures, defaults, or behavior.
- **Prefer existing implementations.** Use well-maintained third-party packages over reimplementing functionality. Search for established libraries before writing from scratch.
- **Non-reusable is a smell.** Prefer reusable domain primitives over one-off code. `./internal` is such a smell: code under it is unimportable from other modules.

## Strong Typing

- Named types for domain concepts (`type UserID uint64`, not bare `uint64`). Typed constants with iota. Use generics instead of `any`/`interface{}`.
- Choose the underlying type by the domain's value space and operations, never by minimal byte width alone. A set of named values goes on an integer kind. For a closed set or fixed flag set whose wire form is fixed, keep the integer backing and translate in the marshalers. An ordered quantity goes on `int` unless range exceeding `int32`, interop, or footprint over millions of instances forces a specific kind. Fractional values go on integer kinds when exactness is required, float kinds only where rounding error is acceptable. A fixed set of up to 64 independent combinable flags goes on `uint64`. A growing flag set, or one over 64 flags, goes on a struct of bools.
- Group related behavior through types, method sets, and interfaces — let the type system encode domain relationships instead of scattering them across unrelated functions.
- One source of truth per logic/constant — define once, reference everywhere. Duplicated values drift.
- Return values must be orthogonal. If a caller can derive one result from another without losing information, return only the authoritative result. Add another result only for independent state or ambiguity the authoritative result cannot encode.
- Struct fields are exported by default. Only unexport a field when external mutation would violate an invariant maintained by the type's methods.

## File tree

- Keep a semantic group's members together — one domain concept: a type with its constructors, methods, and tightly-coupled helpers, plus types that share those helpers. Split a large group across files by sub-concern, and split a file holding multiple groups into per-group files, whenever each resulting file carries a complete concept (cohesion, not line count).
- A declaration belongs in the non-exempt file of the group it serves or that most uses it, within its package; never alone in a file carrying no complete concept. When several files fit, or none does, keep the current file. Exempt: main.go, doc.go, test files, generated code.
- Never use abstract file/directory/function names (like "helper", "wrapper", "adapter"). Every name should specifically and unambiguously explain the content, and every used word in the name has high cost.

## Naming

Multi-parameter functions: each parameter on its own line, closing `) returnType {` on separate line:

```go
func (n *NodeWithCustomData[C, T]) RemovePushTo(
	ctx context.Context,
	to Abstract,
) (_err error) {
```

## Error Handling

- **Never blanket-ignore errors.** Suppress only errors matched explicitly by type or value (`errors.Is`/`errors.As`). Any unknown error is the worst case — if the function returns `error`, propagate it; never swallow.
- **Fallbacks belong at external boundaries.** For failures in code we own, fix the failure or return it. Add fallback paths only for explicit failure modes of external systems, dependencies, hardware, or environments.
- Function signatures return `error`, never a concrete error type (`*ParseError`, `ErrFoo`). Use concrete types only for construction and `errors.As`/`errors.Is` matching.
- Custom error types implement `Unwrap() error`.
- Accumulate errors in `var errs []error`, return `errors.Join(errs...)`.
- Switch on error type:
  ```go
  switch {
  case err == nil:
  case errors.As(err, &ErrNotImplemented{}):
      logger.Warnf(ctx, "...")
  default:
      return fmt.Errorf("...: %w", err)
  }
  ```
- Deferred logging with named returns:
  ```go
  func (c *Codec) Close(ctx context.Context) (_err error) {
      logger.Tracef(ctx, "Close")
      defer func() { logger.Tracef(ctx, "/Close: %v", _err) }()
  ```
- Cleanup-on-error via defer:
  ```go
  defer func() {
      if _err != nil {
          _ = c.Close(ctx)
      }
  }()
  ```

## Concurrency

- `context.Context` is always the first parameter. Never stored in structs.
- Goroutines via `observability.Go(ctx, func(ctx context.Context) { ... })`, never raw `go`.
- **Prefer atomics over locks.** Use `sync/atomic` for single-word state (`atomic.Pointer[T]` for pointers). Prefer CAS (`CompareAndSwap` loop) for multi-step non-blocking transitions. Hold a mutex only when the mutation cannot be swapped atomically, guards an invariant atomics cannot express, or performs blocking work.
- **Narrow what a mutex guards.** Keep the critical section to the fields one invariant requires. Split a long-lived state container from the code that mutates it so retries need not hold a global lock. This narrows lock scope at runtime; **One audience per struct** narrows the data type by audience.
- Mutex unlock always via `defer`. Prefer small functions that lock/defer-unlock at the top, rather than locking inside complex functions with multiple code paths.
- **Timeouts are a design smell when the event is observable.** Reacting to a `time.Sleep`/`time.After`/poll-loop to "wait for" something that can be subscribed to (channel, `sync.Cond`, `ctx.Done()`, `fsnotify`, callback, signal) is a workaround, not a fix. Subscribe to the event. Reserve timeouts for genuinely opaque waits (network round-trip, hardware response, third-party process you cannot instrument) — and even then as an upper bound on top of the event, not a replacement for it.

## Types & Generics

- Option pattern:
  ```go
  type Option interface { apply(*Config) }
  type Options []Option
  func (opts Options) config() Config { cfg := defaultConfig(); opts.apply(&cfg); return cfg }
  type optionCheckInterval time.Duration
  func (o optionCheckInterval) apply(c *Config) { c.CheckInterval = (time.Duration)(o) }
  ```

## Function Values

- Prefer named interfaces over anonymous functions/closures. They hide behavior, defeat method discovery, capture state implicitly, and do not serialize.
- Prefer serializable constructs. Values crossing a boundary such as RPC, config, snapshot, replay, or audit log must be data, not closures.
- Anonymous functions are OK only for `defer`/`go`/`observability.Go` bodies, one-off `sort.Slice` less funcs, and test closures. Anything reused, stored, or passed across packages uses a named type plus interface.

## Other patterns

- Never use `else if`. Always use `switch` if semantically there could be more then 2 options. Even if in practice you currently have 1-2 options, but semantically there could be more, it still should be a `switch`.

## Logging

- `github.com/facebookincubator/go-belt` via context: `logger.Debugf(ctx, "...")`.
- Logger is always derived from `context.Context`. Never store a logger in a struct.
- Structured fields: `belt.WithField(ctx, "key", value)`.
- Entry/exit tracing: `logger.Tracef(ctx, "MethodName")` / `logger.Tracef(ctx, "/MethodName")`.
- Do not reference stdin/stdout/stderr outside of the `main` package.
- **Level semantics** (use the right level for the situation):
  - `Trace` — method entry/exit, low-level flow tracing.
  - `Debug` — normal operational messages, state changes, request handling.
  - `Info` — rare, notable events only (startup, shutdown, config reload). Most messages should be `Debug`, not `Info`.
  - `Warn` — recoverable problems, degraded operation, unexpected-but-handled conditions.
  - `Error` — operation failed, needs attention but process continues.
  - `Fatal` — unrecoverable, process must exit.
- **Level consistency:** When adding log statements, scan how the same package uses levels for similar operations and match. If existing usage conflicts with the level definitions above, raise the inconsistency to the user after finishing the task.

## Testing

- `github.com/stretchr/testify` — `assert` for soft, `require` for fatal.

## Code Organization Principles

- Blank line between logical blocks within functions. Never double blank lines.
- Constants as `const` block at file top, not magic values inline.

## General discipline

- After every change: reduce code in related pieces. Remove logic, not lines. Keep readable.
- When a workaround feels ugly, treat it as a design smell — find the elegant approach.
- Validate inputs with strong expectations. When there's no error channel, use assert/invariant.
- Small functions, but keep semantically self-sufficient thoughts whole.
- Satisfy all linters — they catch real bugs before runtime.
- **Self-explanatory code.** Code must explain itself through names, types, control flow, or comments. If a reader cannot tell why an approach, system, protocol, component, workaround, or dependency was chosen, treat that as a code smell and make the rationale discoverable.
- **Comments explain rationale, mechanics, or next steps.** Comments serve future readers of the code, not a record of how it was written. No session-internal context — never reference session task numbers (`#350`, `task #10`), session/agent IDs, `RCA:` / root-cause prefixes, "fix from review", "per critic", "generated by AI", or other authoring-process artifacts. If a fix references an external tracker, use the real issue URL/ID, not a harness-internal counter.
- **Eliminate tech debt on contact**: Fix generators rather than editing generated files.
- **Use authoritative sources over generation**: Download or reference canonical sources (LICENSE, .gitignore templates, config schemas) instead of generating from memory.
- **No hidden assumptions.** Handle exactly the cases you expect. Return errors for everything else. A condition like `x > y` silently accepts cases you didn't consider — use explicit checks for each supported case and error on the rest.

## Semantic integrity

A name is a contract — implementation fulfills exactly what the name promises.

- **Does only what it says.** `resolveTable` resolves a table — not decide *whether* to, retry, or log analytics. Extra behavior belongs in the caller or the name.
- **Does everything it says.** `ValidateAndSave` must validate and save. If either can happen without the other, split or rename.
- **Interface implementation is a contract.** Implementing an interface claims "I fulfill this." Always-erroring or no-op primary methods = violation. Deferred is not an implementation strategy — either implement or don't create the type yet.
- **No opposite behavior.** `disable` must not return an "enabled" state. `remove` must not archive.
- **Return type matches name.** `GetUser` → User. `IsValid` → bool. `ListItems` → collection.
- **No smuggled decisions.** `doX()` assumes X should happen. "If not needed, return early" inside it is a violation — the caller decides.
- **No smuggled side effects.** Getters don't mutate. Predicates (`Is`, `Has`, `Can`) don't change state. If they must, the name must reveal it.
- **One concern per contract.** Keep policy, orchestration, I/O, persistence, observability, and domain logic behind the function, type, or package contract that owns them. Split mixed work unless one precise domain concept owns the combination.
- **One audience per struct.** Data that describes an entity existing independently of the owner (descriptive metadata, shared spec, shared config) is its own type; the owner's private runtime state (locks, channels, open handles) is another. Being exported does not make a field its own audience: a lock stays with the state it guards. Compose by reference or embedding. Do not flatten both into one struct unless splitting would lose an invariant the combination exists to maintain. Example: a job's `ID`/`Description`/`Schedule` describe a job that exists with no runner present; the runner's `mu`, `cancel chan` exist only while it runs — two types, the runner holding the descriptor.
- **Package scope.** Verify code belongs in THIS package/binary. A package named `foocli` (standalone tool) must not contain code requiring a running `food` daemon.

Review check: read the name, predict the body, read the body. Any surprise is a violation.

## Semantic consistency

Same concept → same name everywhere. Same name → same meaning everywhere. Related concepts → parallel structure.

- **One name per concept.** "stream" everywhere — not "channel"/"feed"/"pipe" in different packages for the same thing.
- **One concept per name.** `Handle` can't mean "process a request" here and "resource reference" there.
- **Parallel pairs.** `StartCapture`/`StopCapture` — not `BeginEncoding`/`EndEncoding`. Pick one verb set per domain.
- **Full rename propagation.** "job" → "task" means types, functions, variables, logs, errors, comments all change. Partial rename is worse than none.
- **Consistent abstraction level.** Sibling calls: `initializeCluster`, `configureNetwork`, `go` — the last one breaks the level.
- **Domain names, not implementation.** `StreamProcessor` over `MapWithMutex`. Name must survive an implementation change.

## Locality and lifetime

Everything as local as possible, as short-lived as possible.

- **Narrowest scope.** Variables live in the innermost block that needs them. Use `:=` in `if`/`for`/`switch` init statements.
- **Shortest span.** Minimize distance between declaration and last use. A variable declared at line 1 and next used at line 20 means the code between should be restructured or the variable moved closer.
- **Release early.** Close/release resources as soon as done — not deferred at function top when the resource isn't needed for the full function body.
- **No package-level when local suffices.** Package-level `var` is global state. Use only when multiple functions genuinely share it.
- **No stale references.** Don't store pointers that outlive the data's logical lifetime (closed connections, expired cache entries, finished request contexts).

## Be consistent

- If you are modifying a package, scan other files in the package and follow the same patterns. If some pattern is
  suboptimal, then raise the question (if needs to be fixed) to the user after finishing the task.
- **Fix violations on sight.** When reading or modifying code, if you encounter an obvious violation of these rules in the surrounding code, fix it. Don't leave known violations behind.

## Modules

- Use `go.work` for local module resolution with paths relative to the workspace file. Keep `go.mod` free of local filesystem paths; remote fork replacements are fine. Reserve absolute paths for tool-required cases.

## Readability

- Keep code flat. Avoid deeply nested `if`/`for`/`switch` blocks. Use early returns, `continue`, and guard clauses to reduce nesting. If a block is nested 3+ levels deep, refactor it.
- When replacing one approach with another (e.g., to fix a bug), add a comment explaining why the new approach was chosen.
