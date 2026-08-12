# Android Workbench decision record

This record preserves the durable design decisions that shaped Android
Workbench before and during its extraction into a standalone repository. It
explains why current boundaries exist; current behavior remains defined by the
vimdoc and tests.

## AN001 — Build a focused, swappable Android workflow

- **Status:** Accepted
- **Decision:** Build Android Workbench as an Android-only orchestration layer.
  Reuse optional picker and task libraries through explicit adapters, retain
  dependency-free native defaults, and keep Gradle discovery, ADB coordination,
  target state, emulator lifecycle, build problems, and app-scoped Logcat under
  focused internal ownership.
- **Requirements:** Support multi-module and composite Android projects, exact
  application/variant/device selection, trusted and cancellable Gradle
  execution, Build/Run/Stop, arbitrary registered Gradle tasks, inspectable
  output, emulator lifecycle, and Logcat without taking over unrelated editor
  behavior or requiring one presentation plugin.
- **Considered:** Existing Android Neovim plugins, Gradle-specific plugins,
  Overseer alone, generic task frameworks, raw terminal commands, the Android
  CLI, and a focused owned implementation composed with maintained libraries.
- **Rationale:** Existing plugins either own a broader IDE surface or do not
  expose the trusted composite-build model required here. A task runner can own
  task lifecycle and presentation but does not supply the Android/Gradle domain
  model. Explicit adapters let a consumer choose Telescope or Overseer without
  leaking them into core behavior.
- **Tradeoffs:** Workbench carries more code and has less public adoption and
  release maturity than established plugins. Its adapter contracts must remain
  deliberately small and well tested.
- **Consequences:** The package defines one namespaced command and facade, but no
  global mappings, WhichKey dependency, autosave, watcher, LSP, formatter, DAP,
  or test runner. Consumer mappings and concrete presentation choices remain
  outside the package. New providers are added only for real alternatives; no
  registry, automatic detection, or dependency-injection container is implied.
- **Revisit when:** A maintained community plugin satisfies the same trust,
  composite-build, coexistence, and swappability requirements, or daily use
  exposes an ownership flaw.

## AN002 — Refactor only at demonstrated lifecycle seams

- **Status:** Accepted
- **Decision:** Preserve the public facade, `App` composition root, explicit
  ports, and current workflow semantics. Reject broad rewrites and
  file-size-driven splits. Refactor only when characterization demonstrates a
  cohesive lifecycle or removes a correctness hazard.
- **Requirements:** Establish behavior before moving it; keep trust adjacent to
  project execution; handle synchronous callbacks, exactly-once terminals,
  stale generations, cancellation refusal, bounded output, root isolation, and
  revision-safe selection updates.
- **Considered:** Splitting `App`, ADB, emulator, or native Logcat because of
  line count; a dependency-injection container; provider registries; broad
  compatibility abstractions; retaining every duplicated orchestration path;
  and a full rewrite.
- **Rationale:** Large lifecycle modules are not automatically incohesive. The
  demonstrated seams were a provider-neutral task operation, shared
  model/target/device preflight, and unified device coordination once AVD work
  existed. Each gives one owner a real lifecycle without widening public API.
- **Tradeoffs:** Some modules remain large. That is preferable to distributing
  tightly coupled state transitions or creating speculative public seams.
- **Consequences:** `task_operation.lua` owns neutral task validation, bounded
  output, and terminal behavior for native and Overseer runners. `App` owns
  shared preflight and remains the only composition root. Device coordination
  owns unified inventory and stable selection without becoming a generic device
  framework.
- **Revisit when:** A responsibility gains an independently testable lifecycle,
  a second implementation needs a different boundary, or measurements show a
  current owner is a bottleneck.

## AN003 — Model AVDs as stable resources behind a semantic emulator port

- **Status:** Accepted
- **Decision:** Represent a stopped AVD as `{ avd_name }` and a running emulator
  as `{ avd_name, serial }`. Keep unified physical/running-AVD/stopped-AVD
  inventory and revision-safe selection in the device coordinator. Put
  list/start-to-ready/exact-stop behavior behind a semantic emulator port while
  raw ADB parsing remains in the ADB service.
- **Requirements:** Use direct argv with the classic emulator and ADB tools.
  Revalidate serial plus AVD name, reject ambiguous duplicates, use bounded boot
  readiness, and wait for stop disappearance. Cancellation may terminate only a
  launcher process Workbench created and still owns. Ready, adopted, and
  pre-existing emulators outlive the operation and Neovim.
- **Considered:** Routing the long-lived emulator through the Gradle runner or
  Overseer, exposing a generic process port, using an emerging Android CLI as
  the default, importing Android Studio state, separate ADB/AVD action hubs, and
  adding a generic polling framework.
- **Rationale:** Emulator process exit is not workflow success; exact boot
  readiness is. A semantic lifecycle keeps that distinction out of the task
  runner. Stable AVD names preserve intent across console-port changes without
  weakening wrong-device protection.
- **Tradeoffs:** The native implementation targets local classic emulator
  instances with console-port serials. Its in-process same-name guard cannot be
  atomic across separate Neovim processes, so a final live identity scan remains
  authoritative. A custom ADB service may need a paired custom emulator service
  for native AVD workflows.
- **Consequences:** Device selection presents one neutral inventory. Run may
  start a remembered stopped AVD by explicit configuration; application Stop
  and Logcat never do. AVD creation, deletion, wiping, cold boot, snapshots, SDK
  installation, Android Studio state, and an embedded emulator remain outside
  scope.
- **Revisit when:** A second mature emulator backend needs different semantics,
  a cross-process duplicate problem becomes observable, or a supported platform
  cannot implement the current exact-identity contract.

## AN004 — Separate Gradle problem collection from presentation

- **Status:** Accepted; extended by AN005
- **Decision:** Parse bounded Build/Run/Gradle-task output into neutral source
  problems, carry them through runner results, and publish one accepted terminal
  batch through an explicit problem-sink port. Use a root-keyed native quickfix
  sink as the dependency-free default.
- **Requirements:** Preserve native-runner and optional-runner parity, root
  isolation, cancellation ownership, and stale-terminal rejection. Publish only
  after the active operation accepts a valid Gradle terminal. A success clears
  only that root's Workbench result; cancellation and failures before a Gradle
  terminal preserve it. Never select or close unrelated quickfix history.
- **Considered:** Publishing directly from Overseer parsers, parsing only final
  captured tails in `App`, automatic Trouble components, diagnostics as the
  canonical store, a parser registry, and a neutral terminal batch with an
  explicit native presenter.
- **Rationale:** Task output parsing, terminal acceptance, problem storage, and
  window policy have different owners. Keeping them distinct prevents provider
  UI state from changing before Workbench accepts a terminal and gives native
  and optional runners the same core boundary.
- **Tradeoffs:** The focused matcher recognizes only fixture-backed Kotlin,
  Java, Android Lint, AAPT, and AGP locations. Locationless and unfamiliar
  failures remain in runner output. The built-in sink owns only the latest list
  per root rather than a full history UI.
- **Consequences:** `ports.problems.publish(batch)` is synchronous and
  presentation-neutral. Problem DTOs carry normalized absolute paths,
  one-based positions, bounded messages, severity, and truncation state.
  Reveal/close behavior belongs to a constructed sink, not top-level setup.
  Trouble is never required or opened automatically. The dependency-free
  native runner separately owns one latest bounded output view per canonical
  root and reopens it through `:Android output`; custom runners retain their own
  output and window policy.
- **Revisit when:** Real output justifies another recognized format, a second
  presenter needs additional neutral data, or the terminal policy must represent
  a demonstrated workflow that the current batch cannot express.

## AN005 — Keep diagnostics an explicit projection over canonical quickfix

- **Status:** Accepted
- **Decision:** Keep the native root-keyed quickfix sink as the default and
  canonical complete problem collection. Offer an optional native diagnostic
  decorator with a dedicated namespace per root. Do not add a top-level
  presentation option, require Trouble, or change runner terminal ownership.
- **Requirements:** Deliver accepted batches to the downstream sink, retain root
  isolation and success/cancellation semantics, and keep diagnostic state in
  memory. Project only into eligible unmodified buffers, invalidate a buffer's
  build diagnostics after edits, and never load or read source merely to
  decorate it. Do not retain a problem-batch cache.
- **Considered:** Quickfix alone, replacing quickfix with diagnostics, direct
  publication from runners, automatic Trouble opening, retaining diagnostics
  after source edits, and explicit decoration of the canonical sink.
- **Rationale:** Native diagnostics give consumers signs, underlines, inline
  messages, navigation, status, and optional diagnostic browsers without adding
  another task or output owner. Explicit decoration preserves the accepted-
  terminal gate and keeps the package default restrained.
- **Tradeoffs:** Build diagnostics are compiler snapshots, not live analysis.
  Editing invalidates them until a later accepted failure. A language server may
  publish an equivalent diagnostic, so consumers can see duplicates. Modified
  buffers rely on quickfix as the complete build-result view.
- **Consequences:** Consumers may construct
  `integrations.diagnostics.new({ sink = quickfix })`. This adds no mapping,
  global diagnostic policy, persistence, or Trouble integration. A downstream
  rejection returns before diagnostic mutation.
- **Revisit when:** Daily use shows misleading duplication, edit invalidation
  hides useful context, or another diagnostic consumer needs more neutral
  metadata.

## AN006 — Discover registered Gradle task names without realizing tasks

- **Status:** Accepted
- **Decision:** Extend the trusted Android model with exact names of registered
  Gradle tasks and execute one selected task through existing discovery, picker,
  runner, cancellation, and problem-sink boundaries. Keep discovery names-only
  and non-realizing.
- **Requirements:** Always present a flat lexically sorted exact-ID picker,
  including a singleton. Treat the returned ID as untrusted, resolve it against
  the offered set, discover normally again, and resolve it from the current
  complete snapshot. Reject disappearance as stale, then authorize immediately
  before direct wrapper execution. Do not read or mutate target/device state or
  invoke ADB.
- **Considered:** Parsing `gradlew tasks --all`, realizing tasks for groups and
  descriptions, caching a second catalog, shell strings and free-form arguments,
  a separate Gradle plugin/UI owner, and extending the existing bounded provider
  with `TaskContainer.names`.
- **Rationale:** The established model already owns trusted multi-build identity
  and freshness, while the runner owns cancellable output. Registered names are
  a non-realizing Gradle surface. Reusing those owners avoids prose parsing,
  stale secondary caches, shell quoting, another output view, and hard
  dependencies on picker/task plugins.
- **Tradeoffs:** The picker cannot show groups or descriptions without realizing
  task objects. Rule-synthesized tasks are accepted by Gradle but absent from the
  catalog. Composite identity before Gradle's public build-path API must fail
  closed when parent/include relationships are ambiguous. Very large projects
  may produce a long flat list.
- **Consequences:** The neutral task DTO is exactly
  `{ id, build_path, project_path, name }`. Execution uses direct argv equivalent
  to `{ wrapper, '--console=plain', exact_id }` at the canonical root, with no
  shell, extra args, device environment, or persisted task choice. The package
  adds no mapping or provider dependency for this workflow.
- **Revisit when:** Gradle exposes stable non-realizing task metadata, real use
  needs bounded search context, task-rule-only tasks become a concrete workflow,
  or the exact-ID contract must support another demonstrated execution mode.

## AN007 — Separate package source from consumer policy

- **Status:** Accepted
- **Decision:** Maintain the reusable runtime, bundled provider, vimdoc,
  architecture, and contract tests in this standalone repository. Keep package
  installation, optional-adapter composition, mappings, and editor-wide policy
  in consuming configurations.
- **Requirements:** Preserve the module namespace, command grammar, state path,
  and native behavior during extraction. The package must load and test without
  a consumer configuration or optional dependencies. A consumer pins one
  external revision and does not retain a second runtime copy.
- **Considered:** Keep the package embedded; retain synchronized copies; freeze
  and release every reachable module immediately; or establish one pre-release
  package source with external consumers.
- **Rationale:** Independent source, tests, CI, documentation, and issue history
  let package work proceed without coupling it to personal configuration work.
  One installed source also prevents runtime and help ambiguity.
- **Tradeoffs:** Consumers now depend on package installation and revision
  updates. Source visibility does not make the current pre-1.0 API stable or
  close the licensing and release gates.
- **Consequences:** Package changes use this repository's tests and roadmap.
  Consumer repositories test only their installation, mappings, optional
  adapters, and coexistence policy.
- **Revisit when:** No active consumer remains, another package boundary proves
  simpler, or the release roadmap selects a licensed stable API.

## AN008 — Support one closed pre-1.0 facade

- **Status:** Accepted
- **Decision:** Treat `require('android_workbench')` as one closed action facade.
  Support its documented setup, context, synchronous queries, async workflows,
  handles, results, structured errors, and shutdown semantics. Keep command
  notification fallback and reachable lifecycle/model modules private.
- **Requirements:** Keep `setup()` optional and configuration-only with no
  return value. Reject invalid programmer inputs before starting work. Normalize
  operational failures to owned `{ code, message, root?, details? }` tables,
  return no result beside an error, preserve lifecycle-handle identity, and
  state the shutdown exception to callback delivery.
- **Considered:** Treating every require-able module as public, continuing to
  expose `_notify`, returning the private effective configuration from
  `setup()`, allowing strings and open-ended tables as public errors, and
  withholding all Lua APIs in favor of commands alone.
- **Rationale:** Consumers need callable actions and explicit constructors, but
  do not need composition-root or model internals. A closed facade catches
  typos, prevents adapter details from becoming accidental promises, and gives
  callbacks one error/result convention without widening the port layer.
- **Tradeoffs:** This is an intentional `0.x` boundary rather than a `1.0`
  compatibility guarantee. Constructor modules remain necessary for explicit
  composition, while exact port DTO maturity is handled separately. Shutdown
  suppresses pending callbacks instead of manufacturing terminals after their
  owner has been irreversibly revoked.
- **Consequences:** `_notify` moved behind an internal module, `setup()` returns
  nothing, context accepts only `bufnr`, `path`, and `root`, public errors have
  four named fields, and internal module reachability grants no support. The
  narrow `is_project()` query lets consumers test Gradle-root membership
  without exposing the canonical root, resolver implementation, or filesystem
  seams.
- **Revisit when:** A demonstrated consumer needs another facade action or
  result field, a supported port requires a public constructor change, or the
  first stable release sets a stricter compatibility policy.

## AN009 — Support four replacement ports during 0.x

- **Status:** Accepted
- **Decision:** Support the exact picker, runner, problem-sink, and five-method
  ADB replacement contracts during `0.x`. Keep emulator, Logcat, discovery,
  trust, notification, and state replacement DTOs experimental until a
  demonstrated external consumer and a closed receiving boundary justify each
  promotion.
- **Requirements:** Document every supported field and calling convention, keep
  shared conformance fixtures, pass owned values across the boundary, and
  revalidate identity-bearing returns. Keep the public ADB service limited to
  `list_devices`, `validate_serial`, `resolve_launch_components`, `launch`, and
  `stop`; native emulator and Logcat helpers remain conditional private
  capabilities.
- **Considered:** Treating all ten injectable ports as equally supported,
  withholding all replacement contracts until `1.0`, supporting only the three
  demonstrated presentation/task seams, and adding native ADB helper methods to
  the general service.
- **Rationale:** Picker, runner, and problem presentation are active consumer
  composition seams. ADB is also needed for a complete custom device and
  application workflow, and its five core methods already have bounded native
  DTOs and focused lifecycle coverage. The other ports have usable native
  implementations but no evidence that their current replacement shapes are
  the right compatibility promise.
- **Tradeoffs:** Intentional constructor modules and working native defaults do
  not imply that every matching replacement DTO is stable. Experimental ports
  can change during `0.x` with a changelog entry but without a compatibility
  bridge. Custom ADB services that retain native Logcat or emulator composition
  may deliberately implement extra private capabilities.
- **Consequences:** Supported ports have exact vimdoc, LuaCATS annotations, and
  shared structural fixtures. Runner and ADB results are closed before they
  reach facade workflows. The remaining six ports are still injectable and
  tested as current behavior, but consumers assume pre-1.0 change risk.
- **Revisit when:** A real consumer needs an experimental replacement contract,
  the first stable release selects a compatibility policy, or a supported DTO
  cannot express a demonstrated workflow.

## AN010 — License the repository under MIT

- **Status:** Accepted
- **Decision:** License Android Workbench under the MIT License with copyright
  held by Gage Vander Clay beginning in 2026.
- **Requirements:** Distributions retain the copyright and permission notice.
  Record copied, adapted, generated, or vendored material in the provenance
  inventory before distribution and add a `NOTICE` file only when an additional
  attribution obligation requires one.
- **Considered:** Keeping the repository unlicensed until the first tag and
  copying the incomplete license text from the former embedded configuration.
- **Rationale:** The owner selected MIT. Git history records one author for the
  extracted implementation and its standalone changes, and the provenance
  inventory found no additional attribution notice.
- **Tradeoffs:** MIT permits reuse without promising API stability or a tagged
  release. Recorded history and source scans cannot prove that no unrecorded
  source was ever consulted.
- **Consequences:** Source recipients may use, modify, and redistribute the
  repository under the MIT terms. Release verification remains independently
  gated by the roadmap.
- **Revisit when:** Ownership changes or new material introduces another
  license or attribution obligation.

## AN011 — Spool hidden native Logcat history privately

- **Status:** Accepted
- **Decision:** Keep each native UID-scoped Logcat reader active when its last
  window is hidden, but move its retained history out of parsed Lua records and
  buffer lines into bounded private temporary storage. Restore the newest
  retained history when the handle is shown again.
- **Requirements:** Preserve the existing logical-line, record-count, and raw
  record-byte bounds. Serialize asynchronous reads and writes, bound queued
  payload, use at most two active rolling files, create files with mode `0600`,
  and unlink each pathname immediately after opening. Stop, wipeout, terminal
  exit, and shutdown must close every descriptor. Filters, pause, follow, and
  capture identity remain in memory. A storage failure warns and falls back to
  bounded memory.
- **Considered:** Keeping every hidden history parsed in memory, stopping a
  reader when hidden, retaining named temporary files, persisting captured
  messages across Neovim sessions, and sharing one device reader.
- **Rationale:** A hermetic measurement found that four saturated current
  sessions added 47.34 MiB of RSS and eight added 99.80 MiB. Hidden spooling
  follows Android Studio's memory-saver lifecycle without changing Workbench's
  app-scoped capture model or making hidden state durable.
- **Tradeoffs:** Hiding and showing now perform local filesystem I/O. Rolling
  segment eviction can retain fewer records than the nominal per-session cap,
  and one retired descriptor can live until its already-started write returns.
  Unsupported hosts that cannot unlink an open file use bounded memory instead.
- **Consequences:** Hidden buffers release their parsed record array, rendered
  lines, and source index while ADB capture continues. The private spool module
  is an implementation detail, and no pathname or persisted message history is
  exposed to consumers.
- **Revisit when:** Windows support is accepted, measured disk latency harms
  interaction, captured-message persistence becomes deliberate scope, or a
  shared collector is separately justified.

## AN012 — Switch native Logcat buffers through one owned dock

- **Status:** Accepted
- **Decision:** Let every native Logcat session retain its own buffer and state,
  while handles created by one native presenter reuse the standard bottom split
  that presenter created. Showing a hidden handle replaces only the buffer in
  that owned window and does not stop either reader.
- **Requirements:** Keep dock ownership local to `Native.new()` and outside the
  experimental Logcat port contract. Preserve focus for non-focused shows and
  remember a usable source window across session switches. Focus a session that
  is already manually visible. Never claim floating windows or replace a dock
  after it displays an unrelated buffer.
- **Considered:** Opening one bottom split per session, making the dock a module
  global, exposing a public dock abstraction, forcing every custom presenter to
  use the native layout, and implementing Android Studio-style tabs.
- **Rationale:** One switching viewport avoids a stack of bottom splits while
  independent buffers preserve normal Neovim arrangement and session-local
  state. Presenter-local ownership supplies a useful dependency-free default
  without constraining replacement presenters.
- **Tradeoffs:** The default native presenter applies a small amount of window
  policy. Manually replacing its dock buffer intentionally releases ownership,
  so the next hidden-session show opens a fresh split rather than reclaiming
  that window.
- **Consequences:** Native session switches trigger the existing hide and show
  storage transitions. Users may still display session buffers in other
  windows, and custom `ports.logcat` implementations remain free to use tabs,
  floats, external UIs, or no window at all.
- **Revisit when:** Daily use needs simultaneous native panes as a first-class
  action, tabpage-local docks become necessary, or an external consumer needs a
  reusable presentation coordinator.

## AN013 — Keep independent root-local Logcat sessions

- **Status:** Accepted
- **Decision:** Store live Logcat entries per canonical root, keyed by exact
  application ID and device serial. Opening an existing identity reveals it;
  opening another identity starts a sibling and makes it current. Keep pending
  starts independent and preserve aggregate `running`, `starting`, or `stopped`
  status.
- **Requirements:** Give every live entry an exact generation token. A stop or
  presenter exit may remove only that token. Stop the current live entry when
  no start is pending; otherwise cancel the most recent pending start. A
  refused stop or cancellation retains ownership. Shutdown revokes all pending
  starts, then stops and abandons every live entry before a replacement `App`
  can act.
- **Considered:** One replaceable Logcat slot per root, target/variant-based
  identity, one shared device reader, and requiring replacement presenters to
  share the native dock.
- **Rationale:** Application/device identity matches the accepted Android
  Studio-like workflow while preserving Workbench's UID-scoped capture. App
  owns lifecycle and identity; presenters remain free to own their UI.
- **Tradeoffs:** Each live session owns an ADB reader and independently bounded
  history. The aggregate status cannot identify the current session; selection
  and detailed session state remain separate R4.4 contracts.
- **Consequences:** Different applications on one device and one application on
  different devices can collect concurrently. Run auto-open no longer replaces
  another identity, and late terminals cannot remove a sibling or successor.
- **Revisit when:** A shared collector is justified by measurement, mutable
  capture identity is accepted, or a supported presenter contract needs richer
  session metadata.

## Repository extraction status

Moving the runtime into this repository does not change AN001–AN006. The module
namespace, command, state location, bundled provider placement, and consumer
policy boundary remain intact. Extraction is a packaging and ownership change,
not permission to widen the plugin or freeze every reachable Lua module.

The repository is MIT-licensed but not yet released. Runtime containment,
default output, public API, compatibility, and release evidence are tracked
separately in `roadmap.md`.
