# Android Workbench architecture

Android Workbench is a focused Android orchestration plugin for Neovim. This
document records durable ownership, dependency direction, and lifecycle
contracts. User-visible setup, commands, and controls belong in the
[vimdoc](../../doc/android-workbench.txt). Accepted tradeoffs live in the
[decision record](../decisions.md), and unfinished hardening is tracked in the
[roadmap](../roadmap.md).

## Scope and non-goals

Workbench owns the path from a canonical Gradle-wrapper root to a validated
Android application/variant model, remembered target and device selection, AVD
discovery and emulator start/stop, exact build/install/launch/stop operations,
names-only registered Gradle-task discovery and execution, accepted build
problems, and application-scoped Logcat. It composes picker, runner,
notification, problem, persistence, trust, ADB, emulator, discovery, and Logcat
capabilities through explicit ports.

It does not own Kotlin or Java language tooling, formatting, testing, DAP,
autosave, file watching, editor sessions, global working-directory policy, KMP,
iOS, or unrelated editor behavior. It is Android-only rather than an all-in-one
IDE or a generic task framework.

Library code defines no personal/global mappings, key-hint registrations, or
global picker overrides. Core requests and state do not own provider UI policy.
Replaceable presenters may own policy local to their implementation; the
consuming Neovim configuration explicitly chooses those adapters.

SDK installation, Android Studio state, an embedded emulator, and AVD creation,
deletion, or wiping are outside the boundary. Arbitrary Gradle tasks remain a
bounded Android-project workflow rather than widening Workbench into general
task, SDK, or device management.

## Runtime and public boundary

[`plugin/android-workbench.lua`](../../plugin/android-workbench.lua) registers
the `:Android` command. Its completion grammar is static and must not construct
the application, inspect a project, query ADB, enumerate AVDs, prompt for trust,
or execute Gradle. Registration never replaces an existing global `:Android`
command: the incumbent remains callable and Workbench emits one warning without
loading its command implementation.

[`android_workbench/init.lua`](../../lua/android_workbench/init.lua) is the Lua
facade. It owns setup, contextual argument normalization, the lazy singleton,
and public callbacks. Private `notify.lua` owns command/facade notification
fallback. `setup()` validates and stores configuration only; it must run before
the first action and must not resolve a root, load state, create a session,
prompt for trust, or start work. The first action constructs `App`.

The supported pre-1.0 facade exposes setup, a side-effect-free Gradle-root
membership query, status and action discovery, model refresh, target selection,
emulator start/stop, Build/Run/application Stop, arbitrary Gradle tasks, native
task-output reopen, Logcat start/stop, cancellation, and shutdown. `setup()`
returns no internal configuration data. Notification fallback is owned by a
private module rather than an accidental `_notify` facade member.

Root-aware facade calls accept only `bufnr`, `path`, and `root` context fields.
Invalid setup, context, callback, and target-kind inputs are programmer errors
and throw before an action starts. Operational failures cross the facade as
closed owned `{ code, message, root?, details? }` tables. Public async
callbacks use `(error, result)`, may complete synchronously, and receive exactly
one terminal while their application generation remains live. Failure never
also returns a result. Shutdown explicitly revokes pending callback delivery;
late children remain private, and a later action constructs a new generation.

The facade, health entry, and constructor modules explicitly named in vimdoc
are intentional pre-1.0 entry points. Lua modules are not public merely because
they can be required; `App`, `Session`, root/device services, configuration,
command/action helpers, notification fallback, task operations, state, and
model helpers remain internal. Constructor intent and replacement-port DTO
maturity are separate promises.

`is_project()` delegates to the private root resolver and returns only whether
the context is below a directory containing `gradlew`. It performs no Android
model discovery and exposes neither the canonical root nor filesystem seams.
It must not construct `App`, load state, authorize or execute project code, or
contact Android SDK tools.

The facade owns the mutable DTO members it returns through status, synchronous
errors, and async callbacks. It exposes only the documented error fields and
copies result members at the public boundary while preserving operation and
Logcat handle identity. Extra nested adapter fields are not supported merely
because they survive normalization today.

Root-aware status and action-menu requests may resolve a wrapper and read
private selection state. They still must not authorize project code, discover a
model, query ADB, enumerate AVDs, or start a task.

Consumer-specific adapter selection and buffer-local mappings live outside this
repository. Telescope/Overseer examples are configuration recipes, not default
dependency direction.

## Dependency map

The dependency direction is inward toward neutral domain values and outward
through explicit ports:

```text
command/plugin -> public facade -> private root resolver
                              \-> App (composition root)
                                   |
                                   +-> Session -> trust + Gradle discovery
                                   |                 -> model + metadata
                                   +-> target + Gradle-task helpers
                                   +-> Device -> ADB + emulator + state
                                   +-> Execution -> runner
                                   |                +-> task operation
                                   |                |    -> problem parser
                                   |                +-> native task output
                                   +-> Logcat presenter -> model + runner
                                   +-> picker + notifications + problem sink

consumer configuration -> optional adapters -> public ports
```

This is a responsibility map, not a requirement that every box become a file.
Domain and lifecycle modules must not require a consuming configuration,
Telescope, Overseer, Trouble, or another optional presenter.

## Owners

### App

`App` is the composition root. It constructs native defaults and injected
ports, coordinates complete actions, and owns root-keyed Session,
active-operation, and Logcat registries. Cross-component wiring belongs here.

At most one Build, Run, application Stop, Gradle-task, emulator-start, or
emulator-stop workflow is active per root. Logcat has a separate root-keyed
lifecycle and may survive task completion.

Public shutdown closes and discards the current instance. A later action may
construct a fresh `App`. Shutdown revokes the old generation even when an
adapter refuses cancellation. The child may finish privately, but its terminal
cannot resume App work or affect the replacement instance.

### Session

`Session` owns one canonical root's discovery phase, single-flight discovery,
last complete snapshot, cached selection, and trust/state bridge. Each root has
an independent Session; work under one root must not block, select for, cancel,
or overwrite another.

Ordinary concurrent discovery callers join one flight while retaining
independently cancellable waiters. A forced refresh arriving during discovery
waits for that child to terminate, then starts a distinct replacement. Only a
complete valid result replaces the cached snapshot. Failure or cancellation
leaves the previous complete snapshot available.

A provider without a reliable staleness check is refreshed conservatively. The
native provider may cache a completed snapshot whose bounded fingerprint scan
explicitly exhausted its budget; a forced refresh remains available.

### State

The state adapter is storage, not a second session. It persists only stable
identities: Gradle build/project path, variant, physical-device serial, or AVD
name with its current serial only while known. A stopped AVD has a name and no
sentinel serial.

State is keyed by canonical root, root-validated, owner-private, and atomically
replaced below Neovim's state directory. It is never written into an Android
checkout. In-memory selection and storage must agree after a successful write;
failed writes roll back or use an explicit reconciliation path.

### Gradle discovery and model

`gradle/discovery.lua` invokes the trusted bundled provider;
`android_workbench.init.gradle` emits nonce-scoped bounded records;
`gradle/model.lua` decodes a complete neutral snapshot; and
`gradle/metadata.lua` evaluates bounded staleness inputs.

`gradle/wrapper.lua` owns the regular-file and executable prerequisite shared by
discovery and health. Health reports the prerequisite without executing the
wrapper or authorizing project code.

Discovery output is untrusted data. A snapshot must match the requested
canonical root and contain valid, bounded, closed build, target, and task
collections with exact identities. Native and custom discovery results require
the same owned normalization before they enter Session. Freshness adapters
receive a separate owned copy rather than the cached model.

The bundled Gradle script is a runtime asset kept next to `discovery.lua` so its
source-relative lookup remains independent of package-manager layout.

### Target and Gradle task

`target.lua` owns pure application/variant identity, lookup, sorting, and
labels. `gradle/task.lua` owns registered-task identity, DTO validation,
exact-ID lookup, picker-result resolution, copying, sorting, and labels.

A target or task chosen by a user or adapter is a hint, not authority. Workbench
matches it against the offered set and resolves it again from the current
complete snapshot before execution.

### Device

`device.lua` owns unified physical-device, running-AVD, and stopped-AVD
inventory; picker identity; remembered-device resolution; revision-safe
persistence; and staged start/stop coordination. It does not execute raw SDK
commands.

A running emulator is identified by both ADB serial and AVD name. A stopped AVD
is identified by stable AVD name. Starting converges on that exact name and a
final online identity. Stopping re-resolves the exact serial/name pair before a
targeted kill and waits for disappearance or identity change.

### ADB and emulator

`android/adb.lua` invokes ADB with validated direct argv. It parses connected
devices, emulator identity and readiness, launcher components, application
launch, and application stop.

`android/emulator.lua` implements the native semantic emulator service. It
lists installed AVDs, rejects ambiguous identities, adopts an existing exact
instance, launches a stopped AVD through a detached process, waits for bounded
ADB readiness, and verifies targeted stop through disappearance.

An accepted cancellation, timeout, shutdown, or launch failure may terminate
only a launcher process Workbench created and still owns. A ready or adopted
emulator outlives its operation and Neovim.

The public ADB port covers core physical-device/application workflows. The
supported method-style surface is exactly `list_devices`, `validate_serial`,
`resolve_launch_components`, `launch`, and `stop`. The native emulator service
uses private `resolve_avd_name`, `boot_completed`, and `kill_emulator`
capabilities. Native Logcat conditionally uses private executable resolution.
A custom ADB service that does not supply those native capabilities requires
paired custom emulator or Logcat services; this conditional composition must
remain explicit in public documentation.

### Execution and task operation

`execution.lua` translates a resolved Android or arbitrary Gradle action into
an exact neutral task request and, where required, an ADB follow-up. It does not
own task presentation. Its private abandon transition prevents a late task
terminal from advancing into ADB after App shutdown.

`task_operation.lua` is the provider-neutral primitive shared by native and
Overseer runners. It owns request validation, bounded capture and pending
output, ordered delivery, exactly-once terminal results, and optional neutral
source problems. Native process signaling and Overseer task lifecycle remain
with their concrete adapters. The primitive is not a public generic-task
framework.

The native runner is dependency-free. `task_output.lua` owns one latest
count- and byte-bounded scratch view per canonical root. A native Gradle task
opens its owned split without focus; `:Android output` reopens that same view
after success or failure. Replacement and shutdown invalidate old view
generations before late output can mutate a successor. Custom runners keep
their own output and window policy; the runner port does not require native
presentation methods.

### Problems

`problem.lua` validates, bounds, copies, and deduplicates neutral source-problem
DTOs and terminal batches. `gradle/problems.lua` parses only fixture-backed
Gradle/Android compiler locations. It does not publish editor state.

`integrations/quickfix.lua` is the built-in problem sink. It owns one latest
Workbench list per canonical root and optional reveal/guarded-close policy.
Unrelated lists and history remain untouched.

`integrations/diagnostics.lua` optionally decorates an explicit downstream
sink. Quickfix remains canonical. The decorator owns root-scoped diagnostic
namespaces and edit watches, projects only into eligible unmodified buffers,
and invalidates a buffer's build diagnostics after edits. It may create an
unloaded buffer handle for a referenced path, but never loads or reads source,
persists batches, changes global diagnostic configuration, or imports Trouble.

Only `App` publishes problems after accepting an active, valid,
non-cancelled Gradle terminal. Success publishes an empty batch before Run's ADB
follow-up. Cancellation and failures outside the Gradle task preserve the prior
root-owned result. Sink failure becomes a warning and never replaces the
workflow's primary result.

### Logcat

`logcat/model.lua` parses and filters neutral Logcat records.
`logcat/native.lua` owns the ADB stream, visible bounded record history, scratch
buffer, window-local status and controls, transient shortcut help, filtering,
source navigation, and one presenter-local switching dock. Session buffers,
histories, filters, and readers remain independent. Showing a hidden session
replaces only the buffer in the standard bottom split that the same native
presenter created. A manually visible session is focused in place, and a dock
that displays an unrelated buffer loses ownership before the next show.
`logcat/spool.lua` owns hidden native history. It serializes asynchronous reads
and writes through at most two active rolling
segments, bounds queued payload, creates each file as owner-only, and unlinks
its pathname immediately. One retired segment may remain open only while its
single in-flight write finishes. The scratch buffer contains records rather
than scrolling UI chrome; the native presenter does not alter global mappings
or unrelated windows.

The stream survives application process restarts by resolving the selected
application UID. Replacing a root's stream requires the old presenter to accept
stop; a late old exit must not clear a replacement. Logical-line and retained
record bytes are bounded in addition to record count. An oversized logical line
is discarded through its next newline before parsing resumes. Hiding the last
native window releases parsed records, buffer lines, and the source index while
capture continues into private storage. Showing restores the newest records in
order before reapplying filters. Stop, wipeout, terminal exit, and the native
handle's private shutdown-abandon transition close that storage; the private
transition is not part of the experimental replacement-port contract.
The native dock is likewise private presentation policy; custom Logcat
presenters retain complete ownership of their windows.

### Command, actions, and integrations

`command.lua` parses the static command grammar over the public facade.
`actions.lua` derives a presentation-neutral contextual action list.
Integration modules implement one port each and do not own core lifecycle
state.

Optional modules must defer their external `require()` calls until their
adapter is selected or invoked. Package startup and native defaults do not load
Telescope, Overseer, Trouble, WhichKey, or language tooling.

## Port contracts

One explicitly constructed adapter occupies each port. Missing ports use a
built-in implementation; there is no provider registry or automatic detection.

- **`runner` (supported during `0.x`):** Plain-function
  `start(request, done) -> optional handle`. The closed request carries direct
  `argv`, `cwd`, optional string-map `env`, display `name`, workflow metadata,
  and a neutral output callback. Workbench gives the adapter an owned request,
  retains canonical name and metadata privately, validates the terminal DTO,
  normalizes problem items, and removes unknown result fields.
- **`picker` (supported during `0.x`):** Plain-function
  `select(request, done) -> optional handle`. The closed request contains
  `prompt`, owned `items`, `format_item`, and optional `current`. Dismissal is
  `(nil, nil)`; a returned item is revalidated against the original candidates.
- **`discovery` (experimental during `0.x`):**
  `discover({ root }, done) -> optional handle`. Optional `is_stale(snapshot)`
  decides cache reuse.
- **`adb` (supported during `0.x`):** Method-style `list_devices`,
  `validate_serial`, `resolve_launch_components`, `launch`, and `stop` with
  closed device, component, launch, and stop DTOs. Receiving owners revalidate
  exact serial, package, and component identity. Native-only ADB helpers are
  conditional composition capabilities, not additions to this public port.
- **`emulator` (experimental during `0.x`):** Method-style `list_avds`, `start`,
  and `stop`. Start accepts an AVD name and returns its exact ready device. Stop
  accepts AVD name plus serial and returns the stopped identity.
- **`logcat` (experimental during `0.x`):** `start(request) -> handle`. The
  handle provides method-style `show` and `stop`; terminal exit is reported
  through the request.
- **`trust` (experimental during `0.x`):** Synchronous
  `authorize(root) -> true` or `nil, error`.
- **`state` (experimental during `0.x`):** Synchronous `load(root)` and
  `save(root, selection)`.
- **`notifications` (experimental during `0.x`):** Fire-and-forget
  `emit(event)`.
- **`problems` (supported during `0.x`):** Plain-function synchronous
  `publish(batch) -> true` or `nil, error`. `problem.lua` owns the closed,
  bounded batch and item DTO before any configured sink receives it.

Except for ADB and emulator services, adapter entry points are plain functions
without implicit `self`. Returned handles are method-like and tolerate
`handle:cancel()`, `handle:show()`, or `handle:stop()` as applicable.

Async port callbacks use `(error, value)`, may run synchronously or later, and
must reach one terminal result. Expected failures use callback/return errors
rather than exceptions. Port errors should include `code` and `message`; the
public facade normalizes unexpected strings, exceptions, or malformed tables
before returning them and never pairs a public error with a result.

Ports exchange neutral owned DTOs, not `App`, `Session`, provider tasks,
quickfix IDs, or buffer/window policy. Identity-bearing returns are revalidated
and mutable results are copied at the boundary.

The ten ports are not equal promises of stability. Picker, runner, problem
presentation, and ADB have closed documentation and shared contract fixtures.
The other six ports remain experimental until demonstrated consumers and
closed receiving boundaries justify promotion.

## Async lifecycle invariants

1. Every operation has exactly one terminal completion. Duplicate callbacks,
   late process exits, buffer teardown, and repeated cancellation are ignored
   after that transition.
2. Cancellation is terminal at the layer that owns the callback. Accepted
   cancellation retains ownership until the child terminates. Refusal leaves
   the operation active and observable during ordinary use.
3. Shutdown differs from ordinary cancellation: it irreversibly revokes the
   application generation and suppresses all late outward side effects even
   when a child cannot be stopped.
4. Child ownership is generation-aware. Establish identity before invoking a
   provider because completion may be synchronous. Adopt a returned child only
   when its generation is still current.
5. The leaf process adapter alone owns signal escalation and its timer. Parents
   cascade cancellation but do not race a second termination policy.
6. Root operation slots remain occupied until the owned terminal. Logcat uses a
   separate root-keyed slot and may remain open across task completion.
7. A model-dependent action discovers a complete snapshot, resolves current
   target/device identity, and verifies the final snapshot and selection before
   use. A removed target, stale task, changed selection, or changed emulator
   identity aborts safely.
8. Retained process output, pending scheduled output, discovery records,
   metadata scans, source searches, waits, and Logcat data stay bounded.
9. Neovim APIs and user callbacks run on the main loop. Shutdown closes owned
   resources and makes later callbacks private and harmless.
10. Public results own mutable DTO members. A caller or adapter cannot mutate a
    Session snapshot, retained selection, or later task argv through an earlier
    result.

## Trust, process, and data boundaries

### Trust

Gradle discovery and Gradle Build/Run/arbitrary-task execution run
project-controlled code. Trust is checked immediately before every discovery
process that actually starts and again immediately before each executable task.
It is not hoisted into setup, application construction, status, menu display,
or an earlier preflight step. Cached authorization is observational state, not
permission for a later process.

SDK/ADB-only work—including device/AVD inspection, emulator lifecycle,
application Stop, and Logcat—does not evaluate build logic and does not prompt
for Gradle trust.

### Processes and protocols

External programs receive direct argv and an explicit working directory, never
a shell-composed command. Gradle execution uses the canonical wrapper and exact
qualified tasks from the validated snapshot. Device-scoped installs add only
the selected serial as Workbench-owned environment input.

Discovery accepts only the nonce-scoped, schema-valid, bounded, complete tree
for the requested canonical root. Snapshot freshness is content-based and lazy;
opening a project does not run Gradle or install a watcher. ADB serials,
application IDs, launcher components, device states, and subprocess results are
validated and bounded before entering domain DTOs.

### Selection and persistence

Picker returns and remembered identities are hints. Workbench matches a picked
item against the offered set, a target/task against the current snapshot, and a
remembered device against live identity before use.

An arbitrary Gradle-task picker contributes only a raw task ID. Workbench
resolves it against the offered set, discovers normally again, resolves that ID
from the current complete snapshot, and authorizes immediately before direct
execution.

State contains no provider objects, project code, raw command output, or
presentation state. Field-scoped writes prevent a device-only update from
overwriting a concurrent application/variant choice.

## Testing boundaries

The standalone contract suites are organized by owner:

- [`android-workbench-api.lua`](../../tests/android-workbench-api.lua): command
  and facade laziness, setup/ports, callbacks, actions, root isolation, and
  complete public workflows.
- [`android-workbench-core.lua`](../../tests/android-workbench-core.lua): Session
  single-flight/cache behavior, cancellation, selection writes, and snapshot
  continuity.
- [`android-workbench-state.lua`](../../tests/android-workbench-state.lua):
  validation, root isolation, privacy, and atomic replacement.
- [`android-workbench-device.lua`](../../tests/android-workbench-device.lua):
  unified inventory, identity, selection, start/stop staging, and races.
- [`android-workbench-discovery.lua`](../../tests/android-workbench-discovery.lua):
  provider argv, protocol bounds, cancellation, timeout, and metadata.
- [`android-workbench-model.lua`](../../tests/android-workbench-model.lua): exact
  protocol/model/task invariants and mutation rejection.
- [`android-workbench-runner.lua`](../../tests/android-workbench-runner.lua):
  native/Overseer task parity, capture bounds, delivery order, cancellation,
  exactly-once terminals, and native output ownership, bounds, and reopen.
- [`android-workbench-problems.lua`](../../tests/android-workbench-problems.lua):
  parsing, normalization, quickfix ownership, diagnostics, and clearing.
- [`android-workbench-execution.lua`](../../tests/android-workbench-execution.lua):
  exact Gradle requests, Android follow-ups, failures, and stale callbacks.
- [`android-workbench-adb.lua`](../../tests/android-workbench-adb.lua): direct
  argv, device/emulator identity, launcher parsing, timeouts, and cancellation.
- [`android-workbench-emulator.lua`](../../tests/android-workbench-emulator.lua):
  native AVD discovery, adoption, duplicate protection, readiness, exact stop,
  timeout, and cleanup ownership.
- [`android-workbench-logcat.lua`](../../tests/android-workbench-logcat.lua): UID
  stream/model/presenter behavior, history, navigation, and teardown.
- [`android-workbench-telescope.lua`](../../tests/android-workbench-telescope.lua):
  selection, cancellation, prompt wipeout, and exactly-once completion for the
  optional picker adapter.

`tests/package-smoke.lua` separately verifies ordinary clean plugin loading,
`:Android`, setup/App laziness, no package-defined mappings or eager optional
providers, help, health, and the bundled Gradle asset. These tests do not replace
real Gradle/AGP and optional-provider release gates.

`tests/integration/gradle/` is the explicit real Gradle/AGP lane. It runs the
shipped provider and public facade from disposable floor/current Android
projects, including configuration-cache replay, composite identity, exact task
execution, and APK assembly. `tests/integration/adapters/` loads pinned real
Telescope and Overseer revisions. Neither integration lane is part of the fast
or offline `make test` target.

`tests/fixtures/port_contracts.lua` defines the shared closed field sets for
every supported replacement port. Focused owner suites apply those fixtures to
native outputs and public composition while retaining deeper behavioral tests.

Refactors add characterization before moving a responsibility. Exercise
synchronous, delayed, duplicate, and stale callbacks; cancellation before and
after child adoption; independent roots; and failure at process/persistence
boundaries. Preserve output coalescing, trust adjacency, final identity checks,
and root-isolated state.

## Maintenance and current gaps

Use the vimdoc, this architecture, the decision record, focused tests, roadmap,
and implementation for their distinct responsibilities. Do not duplicate
checkpoint status or compatibility claims in this document.

The standalone extraction preserves the existing runtime namespace, command,
state path, and bundled provider layout. It does not itself close the known
API, licensing, compatibility, or release gates. Those are listed in
`docs/roadmap.md` and must be completed as focused changes rather than folded
into unrelated feature work.
