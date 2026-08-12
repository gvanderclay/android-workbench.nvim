# Multi-session Logcat research and plan

Status: R4.1 through R4.5 are implemented and verified. R4.6 remains planned
post-`v0.1.0` work.

## Desired outcome

Android Workbench should let a user keep multiple independent Logcat sessions
for one canonical project root, including sessions for different applications
on the same device. Selecting a session should reveal its retained output
without stopping another session. Stopping or closing one session should not
affect its siblings.

The Neovim session picker is the practical equivalent of Android Studio's tab
strip. Each native session should read its device independently and apply its
application package filter inside Workbench. Hidden native sessions should keep
collecting while moving their bounded history from memory into private
temporary storage.

## Evidence baseline

This research was checked on 2026-08-12 against:

- the official Android Studio Logcat documentation, last updated 2026-03-06;
- the official Android Studio `studio-2026.1.2` source tag; and
- Android Workbench `11dfd46121e6d3fb62223b60e3117d7da40a40c1`.

Only official Android documentation and source are used for Android Studio
claims below. Source-derived consequences are identified as such.

## Verified Android Studio behavior

### Panels, applications, and queries

Android Studio supports multiple Logcat tabs. A tab can also be split, and each
split has its own device connection, view options, and query. Tabs can be
renamed and rearranged.

When Studio receives a request to show Logcat for an application and device, it
uses a tab name equivalent to `applicationId (deviceId)`. It selects an existing
tab with that name or creates one whose initial query is
`package:applicationId`. Therefore, requests for two applications on the same
device produce distinct panels, while another request for the same named
application/device panel reveals it.

The current panel header contains a device picker and a query field, not a
separate application picker. The application used to create a panel is an
initial query and label rather than an immutable panel owner. A user can replace
that query, rename the tab, or use queries unrelated to an application.

### Capture and filtering

Each `LogcatMainPanel` owns a Logcat job. Its service reads the selected device's
general Logcat stream using `logcat -v long` plus the epoch format where
supported, or a gated protobuf path on newer devices. The command does not
include an application, PID, or UID filter.

Studio enriches messages with application and process names through its process
monitor. The panel retains those messages in its own backlog and applies
`package:`, `process:`, `tag:`, `message:`, `level:`, and other queries inside
Studio.

Source-derived consequence: separate panels connected to the same device each
own a reader and backlog. The inspected Logcat implementation does not share
one device reader and fan its messages out to panels.

### Lifecycle

- Selecting another tab changes presentation; it does not replace the previous
  panel or stop its reader.
- Selecting another device in a panel cancels only that panel's current job,
  clears its captured messages, and starts a reader for the new device.
- Pausing cancels that panel's job. Resuming starts it again.
- Restarting replaces only that panel's job and preserves its configuration.
- Closing a tab or split disposes its panel and owned job.
- Studio persists tab and split layout plus each panel's device, query,
  formatting, wrapping, and mapping configuration. It does not persist captured
  Logcat messages as session state.

### Bounds

Each panel has its own cyclic document and message backlog. The inspected
settings and tests set the default buffer to 1 MiB. The Logcat and
splitting-tabs layers contain no explicit maximum tab count. A hard live-session
count would therefore be a Workbench safety policy, not Android Studio parity.

Studio's feature-gated panel memory saver moves a panel's current backlog into
temporary storage when the panel becomes hidden, clears its in-memory backlog
and document, and writes later messages to the temporary storage while its
reader remains live. When the panel becomes visible, Studio reloads the stored
messages and deletes the files. Closing the panel or ending collection also
deletes them.

The storage uses a rolling pair of files. Rotation occurs after the active file
crosses the configured size, so the implementation can retain approximately
twice the configured threshold. This changes storage while a panel is hidden;
it does not establish a shared device reader.

## Android Workbench at the research baseline

At that baseline, `App` stored one Logcat entry and one pending Logcat start per
canonical root. Its identity contained the selected target, application ID,
device serial, and optional AVD name.

Opening the same identity called the existing handle's `show()` method. Opening
a different identity first required the current handle to accept `stop()`. A
refused or failed stop blocked the replacement and preserved the old stream.
Focused API tests characterized that behavior.

The native presenter resolves the selected package UID and starts:

```text
adb -s DEVICE logcat --uid=UID -b main,system,crash \
  -v threadtime,year,printable -T INITIAL_LINES '*:V'
```

This capture includes application subprocesses and survives application PID
changes. A shared Android UID can include sibling packages. Each native stream
retains at most 10,000 records and 4 MiB of raw record text, with a 64 KiB
logical-line limit.

The native buffer already has the independent behavior a session needs:

- `show()` reveals its buffer;
- `q` hides the view without stopping capture;
- `s` and `stop()` stop that exact stream;
- `p` pauses rendering while bounded capture continues; and
- local filters, follow state, source navigation, and retained records belong
  to the presenter instance.

R4.1 moves hidden native histories into private bounded temporary storage and
restores them when shown. R4.2 lets handles created by one native presenter
switch their independent buffers through its owned bottom split. R4.3 replaces
the single App slot with a root-local registry keyed by application ID and
device serial. Different identities now stay live together; opening an exact
identity reveals it and makes it current. Pending starts are tracked
independently, status remains aggregate, and exact generation tokens prevent a
late exit from removing a successor or sibling. R4.4 adds the public picker and
commands for choosing and stopping those entries. Native in-buffer
discoverability and exact integration evidence remain.

The R4.4 device smoke exposed a capture defect in the original D1 boundary.
After uninstalling and reinstalling the same application ID, Android assigned a
new UID while the retained `adb logcat --uid=OLD_UID` reader remained live. The
session then silently omitted the reinstalled application. The same smoke also
proved that `-T 200` selects the last 200 device-wide records before applying
the UID filter: the exact command returned no application history while the
same UID query without `-T` returned 28 records, including the launch marker.

The corrected native backend follows Studio's capture/filter split. Each
session owns a device-wide reader, asks Logcat to include UID metadata, resolves
the exact package-to-UID mapping independently, and filters records inside
Workbench. The mapping is refreshed while the reader remains live, so a
package reinstall changes temporary capture metadata without changing the
session identity, reader, buffer, filters, or retained history. Workbench uses
bounded package-manager queries rather than copying Studio's JDWP and deployed
native process-tracker implementation. By default the reader consumes the
device's already bounded Logcat buffers without `-T`, as Studio's default live
read does; Workbench's existing record, byte, and logical-line limits remain
the application-history boundary. Device records awaiting the next mapping
refresh are separately bounded by the same record and byte ceilings.

One hermetic clean-Neovim measurement fed 10,000 synthetic records of about 440
bytes into each native session. Four saturated sessions added 47.34 MiB of RSS;
eight added 99.80 MiB. This measures host memory for the current implementation,
not device or ADB-reader CPU cost. A separate local check proved that Neovim can
continue reading and writing an open `0600` temporary file after immediately
unlinking its pathname.

## Parity boundary

| Concern | Android Studio | Planned first Workbench version |
| --- | --- | --- |
| Same device, different apps | Independent panels with package queries | Independent app-scoped sessions |
| Selecting a session | Reveals a panel; siblings keep running | Reveals a buffer; siblings keep running |
| Capture source | Device-wide per panel | Device-wide per session |
| Application association | Mutable query | Fixed package filter and session identity |
| Reader sharing | One reader per panel | One reader per session |
| Visible history | Bounded in memory per panel | Existing bounds in memory per session |
| Hidden history | Feature-gated rolling temporary files | Private bounded temporary storage |
| Session count | No Logcat-specific tab cap found | No arbitrary session cap |
| Persistence | Panel configuration, not messages | Deferred |
| Splits | Supported | Deferred |

The planned user workflow is a verified subset of Android Studio behavior.
Workbench keeps the package filter fixed for a session and does not implement
Studio's general query language, but it now uses the same device-wide capture
and client-side application-filter boundary.

## Accepted direction

- Support multiple simultaneous sessions under one canonical root.
- Support different applications on the same device without replacement.
- Identify and reuse a session by exact application ID and device serial.
- Keep one current session per canonical root.
- Use the supported picker port to select and reveal retained sessions.
- Keep switching, hiding, stopping, and shutdown as separate lifecycle events.
- Keep one shared native Logcat dock and switch its displayed session without
  stopping any reader.
- Keep one device-wide native reader per session and filter it by the session's
  exact application ID inside Workbench.
- Treat UID as refreshed device metadata, never as session identity.
- Keep session history independently count-, byte-, and line-bounded.
- Move hidden native histories into private, immediately unlinked temporary
  files while their readers continue collecting.
- Impose no arbitrary live-session count. Session creation remains explicit,
  and every session remains independently bounded.
- Keep `:Android logcat` as start-or-reveal for the selected application and
  device, add `:Android logcat sessions`, make `:Android logcat stop` stop the
  current session, and add root-local `:Android logcat stop all`.
- Make stop-all best-effort: attempt every current root session, retain any
  session whose stop is refused, and report its identity.
- Preserve the public `status.logcat` field as an aggregate: `running` when any
  session is live, otherwise `starting` when any start is pending, otherwise
  `stopped`.
- Keep mutable session state root-isolated and generation-safe.
- Preserve custom Logcat presenter substitution while its port remains
  experimental during `0.x`.

## First-version non-goals

- Android Studio's general process-name monitor and deployed native tracking
  agent.
- A compatible `package:` or `process:` query language.
- One shared device collector that fans out to sessions.
- Split Logcat views, tab renaming, or persisted session configuration or
  captured messages.
- Global mappings, WhichKey registration, or automatic picker detection.
- Promoting the experimental Logcat replacement port to supported status.
- Changing application selection, device selection, or Run ownership.
- A configurable session-count or aggregate-storage limit without demonstrated
  demand.

## Accepted decisions

- **D1 — Capture:** Keep one device-wide ADB reader per session, include UID in
  each formatted record, refresh the exact package-to-UID mapping while the
  reader remains live, and filter records inside Workbench.
- **D2 — Identity:** Application ID plus device serial defines a session.
  Gradle target, variant, AVD name, and process ID do not create duplicates.
- **D3 — Capacity:** Set no aggregate session-count cap. Creation is explicit,
  and every session's retained history is independently bounded.
- **D4 — Hidden history:** Spool hidden native history to bounded private
  temporary storage while capture continues. Restore it when shown and remove
  it on stop, wipeout, or shutdown.
- **D5 — Presentation:** Native handles share one owned Logcat dock. Showing a
  session makes it current and replaces only the dock's displayed buffer.
- **D6 — Commands:** Add `:Android logcat sessions`; make
  `:Android logcat stop` stop the current session; add
  `:Android logcat stop all` for best-effort root-local cleanup. Buffer-local
  `s` continues to stop its exact session.

## Checkpoint plan

### R4.1 — Private hidden-history storage

- Outcome: Hiding a native Logcat buffer releases its retained records from
  memory while capture continues; showing it restores the newest bounded
  history in order.
- In scope: strict byte, record-count, and logical-line bounds; bounded pending
  writes; rotation; output arriving during hide/show transitions; filtering
  after restoration; retaining session identity, filters, pause, and follow
  state in memory while releasing parsed records, buffer lines, and any source
  index; private `0600` files unlinked immediately after opening; and descriptor
  cleanup.
- Out of scope: multiple App sessions, picker behavior, persisted history, and
  Windows storage semantics.
- Depends on: none.
- Decisions used: D1, D3, D4.
- Automated proof: focused red native contracts for rotation, ordering,
  truncation, restore, duplicate visibility events, late callbacks, stop,
  wipeout, shutdown, supported-host unlink behavior, and absence of a spool
  pathname; then `make test`, `make test-format`, and `git diff --check`.
- Manual proof: none.
- Decision gate: none.
- Status: complete. Focused contracts cover private unlinking and mode,
  rotation, partial reads, ordered filtered restoration, bounded pending
  writes, rapid visibility changes, truncation, stop, wipeout, late callbacks,
  and shutdown abandonment. The full standalone suite, package smokes,
  formatting, help generation, and diff check pass.

### R4.2 — One native Logcat dock

- Outcome: Showing another native Logcat handle replaces the buffer in the
  owned dock without opening another split or stopping either reader.
- In scope: dock ownership, focus preservation, visibility transitions,
  source-window tracking, narrow-window behavior, and unrelated-window
  protection.
- Out of scope: App registry, public session picker, tab emulation, and custom
  presenter UI policy.
- Depends on: R4.1.
- Decisions used: D4, D5.
- Automated proof: focused two-handle native contracts for window reuse, hidden
  spooling, independent filters and history, synchronous callbacks, and exact
  cleanup; then `make test`, `make test-format`, and `git diff --check`.
- Manual proof: deferred to R4.6 because the public App remains single-session
  until R4.3; the native two-handle contract controls switching and output
  arrival directly.
- Decision gate: none.
- Status: complete. Focused two-handle contracts prove exact window reuse,
  independent filtered history and readers, hidden spooling, focus and source
  navigation, synchronous callbacks, narrow controls, ownership loss, unrelated
  window protection, and independent cleanup.

### R4.3 — Independent App session registry

- Outcome: Opening application A and application B on the same device keeps two
  independently live sessions; opening either exact application/device identity
  again reveals its existing session.
- In scope: root-local registries; application/device keys; per-identity pending
  starts; current-session ownership; exact generation tokens; current-session
  stop; aggregate status; synchronous custom presenters; refused cancellation;
  presenter exit; Run auto-open; and irreversible shutdown.
- Out of scope: picker commands, native navigation shortcuts, persistence,
  query changes, and device-wide capture.
- Depends on: R4.2.
- Decisions used: D1, D2, D3, D5.
- Automated proof: focused red API contracts for same-device/different-app
  coexistence, exact-identity reuse, concurrent starts, sibling-safe exit,
  current stop, refusal, stale callbacks, multiple roots, Run auto-open, and
  replacement-App shutdown; then `make test` and `git diff --check`.
- Manual proof: none.
- Decision gate: none.
- Status: complete. Focused contracts prove same-device/different-app and
  same-app/different-device coexistence, exact reuse, concurrent starts,
  current-session fallback, accepted and refused stop/cancellation, sibling-safe
  and stale exits, root isolation, Run auto-open, synchronous presenter exit,
  synchronous shutdown during presenter start, full shutdown, and
  replacement-App isolation.

### R4.4 — Picker, commands, and stop-all

- Outcome: A user can select and reveal a root-local live session, stop the
  current session, or request that every root-local session stop.
- In scope: `:Android logcat sessions`, `:Android logcat stop`,
  `:Android logcat stop all`; public `select_logcat_session(opts, callback)`
  and `stop_all_logcats(opts)` facade methods; contextual action entries;
  closed owned picker items; current-session indication; stale selection
  rejection; picker cancellation; best-effort stop-all with at most 1,024
  reported refusal identities plus total/truncated metadata; vimdoc; changelog;
  architecture; decision record; and roadmap bookkeeping.
- Out of scope: native buffer navigation shortcut, cross-root sessions,
  session mutation, persistence, and arbitrary query editing.
- Depends on: R4.3.
- Decisions used: D2, D3, D5, D6.
- Automated proof: focused command completion and parsing, action, facade,
  result-ownership, picker-mutation, cancellation, partial-stop-refusal,
  stale-selection, and multi-root contracts; help-tag generation,
  `make test`, `make test-package`, and `git diff --check`.
- Manual proof: verify native and configured picker labels clearly distinguish
  two applications on one device.
- Decision gate: none.
- Status: complete. The isolated native smoke installed
  `com.example.workbenchsmoke` and `com.example.workbenchsmoke.second` on
  `emulator-5554`, kept both UID-scoped readers live, showed sorted labels with
  the current session marked, switched both directions without changing the
  three-window layout or reader count, and stopped both readers through the
  public stop-all command. Both app processes and generated Gradle output were
  cleaned afterward. That smoke subsequently exposed the stale-UID defect
  recorded above; its session-control evidence remains valid, while D1 has been
  corrected separately.

### R4.4a — Package-stable native capture

- Outcome: A retained native session continues showing the same application
  after uninstall and reinstall changes its UID.
- In scope: one device-wide reader per session; UID-aware parsing; exact
  package mapping and refresh; bounded pre-refresh classification; full bounded
  device history by default; refresh cancellation and late-callback guards;
  vimdoc, architecture, decision, changelog, and roadmap updates.
- Out of scope: Studio's general query language, JDWP/native-agent process
  monitor, a shared device collector, custom-presenter behavior, and shared-UID
  package separation.
- Depends on: R4.4.
- Decisions used: corrected D1, D2 through D6, and AN015.
- Automated proof: focused red/green native contracts for another UID, named
  Android UIDs, records arriving before remapping, pending bounds, no default
  `-T`, active-refresh stop, refusal, and late callbacks; then `make test`,
  `make test-format`, help generation, and `git diff --check`.
- Manual proof: uninstall and reinstall the selected fixture while retaining
  the exact reader and session buffer; verify old/new UID, reader PID and argv,
  recovered launch marker, and final process cleanup.
- Decision gate: none.
- Status: complete. On `emulator-5554`, the exact uncommitted candidate kept
  reader PID 69645 and its buffer live while
  `com.example.workbenchsmoke` changed from UID 10216 to 10218. The reader argv
  was device-wide, requested `threadtime,year,uid,printable`, and contained
  neither `--uid` nor `-T`. The retained session recovered four post-clear
  launch markers among 105 records. Stop left zero Logcat readers, zero package
  refresh queries, no app process, and no generated app build directory; the
  emulator remained online and the reinstalled fixture remained installed.

### R4.5 — Discoverable native switching

- Outcome: The native Logcat view exposes session switching while live records
  are arriving.
- In scope: one visible buffer-local session control; shortcut-help entry;
  exact current-session labeling; picker callback lifecycle; focus
  preservation; and cleanup after stop or shutdown.
- Out of scope: global mappings, WhichKey integration, splits, tab emulation,
  automatic picker detection, and custom-presenter UI requirements.
- Depends on: R4.4.
- Decisions used: D5, D6 and existing presenter-local discoverability rules.
- Automated proof: focused native UI contracts at normal and narrow widths,
  user `FileType` override preservation, picker cancellation, and stale callback
  suppression; `make test`, `make test-format`, help-tag generation, and
  `git diff --check`.
- Manual proof: confirm the control stays readable while two sessions receive
  logs and that switching does not move source-window focus unexpectedly.
- Decision gate: none.
- Status: complete. The isolated native smoke kept
  `com.example.workbenchsmoke` and `com.example.workbenchsmoke.second` running
  on `emulator-5554` with two readers owned by the exact Neovim process. `S`
  switched the current session through the root-local picker while reusing
  window 1003; the Java source remained in window 1000 and the three-window
  layout did not change. The selected buffer showed the exact application and
  device identity while its sibling remained live and hidden.

### R4.6 — Exact integration evidence

- Outcome: The exact candidate commit demonstrates two application sessions on
  one physical device or emulator without lifecycle, process, or temporary-file
  leakage.
- In scope: start A; start B; verify independent markers; switch repeatedly;
  hide and restore history; restart an application process; reinstall one
  package and verify its retained session adopts the new UID; stop one session
  while its sibling remains live; exercise stop-all; exit Neovim; and inspect
  for surviving Workbench-owned readers or spool paths.
- Out of scope: a device/OS compatibility matrix, Android Studio query parity,
  and a general ADB performance benchmark.
- Depends on: R4.5.
- Decisions used: D1 through D6.
- Automated proof: `make test`, `make test-contract`, `make test-package`,
  `make test-format`, regenerated help tags, and `git diff --check` on the exact
  candidate tree.
- Manual proof: isolated smoke with two distinct installed application IDs on
  one selected device; record exact app PIDs, reader PIDs and argv, session
  identities, retained marker counts, spool-path checks, and final process
  cleanup.
- Decision gate: none. Multiple-reader device and CPU cost remains unverified
  until this checkpoint records it.
- Status: pending.

## Success conditions

- Two applications on one device retain simultaneously live, distinguishable
  Logcat sessions.
- Switching sessions invokes only presentation and starts or stops no reader.
- An application ID and device serial identify exactly one session regardless
  of Gradle target or application process restarts.
- Hidden native sessions retain bounded history without retaining their full
  parsed record set or buffer contents in memory.
- Private spool files have no live pathname after creation and no descriptor
  survives stop, wipeout, shutdown, or normal Neovim exit.
- Exact-session stop, presenter exit, cancellation refusal, and App shutdown
  cannot remove or mutate a sibling session.
- The session picker accepts only a currently owned root-local identity.
- Stop-all attempts every root-local session, retains refused sessions, and
  never affects another root.
- Existing single-session commands, native controls, custom presenters, Run
  auto-open behavior, bounds, and public result ownership remain characterized
  or deliberately changed and documented.
- Full standalone verification and the isolated two-application device smoke
  pass on the exact candidate commit.

## Primary sources

- [Android Studio Logcat documentation][android-logcat-docs]
- [LogcatToolWindowFactory][studio-tool-window]
- [LogcatHeaderPanel][studio-header]
- [LogcatMainPanel][studio-main-panel]
- [LogcatServiceImpl][studio-service]
- [MessageProcessor][studio-processor]
- [MessageBacklog][studio-backlog]
- [LogcatEvent][studio-event]
- [MessagesFile][studio-messages-file]
- [LogcatPanelConfig][studio-panel-config]
- [SplittingTabsToolWindowFactory][studio-splitting-tabs]
- [SplittingTabsStateManager][studio-splitting-state]

[android-logcat-docs]: https://developer.android.com/studio/debug/logcat
[studio-tool-window]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/LogcatToolWindowFactory.kt
[studio-header]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/LogcatHeaderPanel.kt
[studio-main-panel]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/LogcatMainPanel.kt
[studio-service]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/service/LogcatServiceImpl.kt
[studio-processor]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/messages/MessageProcessor.kt
[studio-backlog]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/messages/MessageBacklog.kt
[studio-event]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/util/LogcatEvent.kt
[studio-messages-file]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/util/MessagesFile.kt
[studio-panel-config]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/logcat/src/com/android/tools/idea/logcat/LogcatPanelConfig.kt
[studio-splitting-tabs]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/adt-ui/src/main/java/com/android/tools/adtui/toolwindow/splittingtabs/SplittingTabsToolWindowFactory.kt
[studio-splitting-state]: https://android.googlesource.com/platform/tools/adt/idea/+/refs/tags/studio-2026.1.2/adt-ui/src/main/java/com/android/tools/adtui/toolwindow/splittingtabs/state/SplittingTabsStateManager.kt
