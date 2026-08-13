# Multi-session Logcat

Multi-session Logcat shipped in `v0.2.0`. This document explains how it works,
why it differs from Android Studio, and what was tested before release.

## Goals

Android Workbench keeps independent Logcat sessions for different application
and device pairs under one project root. Selecting a session reveals its
retained output without stopping another session. Hiding a native session keeps
capture active, while stopping or closing one session leaves its siblings
alone.

The session picker is the Neovim equivalent of Android Studio's Logcat tabs.
Workbench keeps its package filter fixed for each session rather than copying
Studio's full query language.

## Android Studio reference

This research was checked on 2026-08-12 against the official Android Studio
Logcat documentation and the `studio-2026.1.2` source tag. The source links are
listed at the end of this document.

### Panels and queries

Android Studio supports multiple Logcat tabs. A tab can be split, and each
split has its own device connection, view options, and query. Tabs can be
renamed and rearranged.

When Studio receives a request to show Logcat for an application and device, it
uses a tab name equivalent to `applicationId (deviceId)`. It selects an existing
tab with that name or creates one whose initial query is
`package:applicationId`. Two applications on the same device therefore open
separate panels, while another request for the same named application/device
panel reveals it.

The application is an initial query and label, not an immutable panel owner. A
user can replace the query, rename the tab, or use a query unrelated to an
application.

### Capture and filtering

Each Studio panel owns a Logcat job. Its service reads the selected device's
general Logcat stream and does not pass an application, PID, or UID filter to
ADB. Studio enriches records with application and process names, stores them in
the panel's backlog, and evaluates `package:`, `process:`, `tag:`, `message:`,
`level:`, and other queries itself.

The inspected implementation gives each panel its own reader and backlog. It
does not share one device reader among the panels.

### Lifecycle and storage

- Selecting another tab changes presentation without stopping the previous
  panel's reader.
- Changing a panel's device replaces only that panel's reader and captured
  messages.
- Pausing cancels that panel's reader; resuming starts it again.
- Closing a tab or split disposes its panel and reader.
- Studio persists panel configuration and layout, but not captured Logcat
  messages.

Each panel has a cyclic document and message backlog. The inspected settings
and tests use a 1 MiB default buffer, and the Logcat tab layer has no explicit
tab limit.

Studio's feature-gated memory saver moves a hidden panel's backlog into a
rolling pair of temporary files while its reader remains active. Showing the
panel reloads the messages and deletes the files. Closing the panel or ending
collection also deletes them.

## Android Workbench design

### Session identity and lifecycle

An application ID and device serial identify one session. Gradle target,
variant, AVD name, process ID, and UID are not part of the identity. Opening an
existing application/device pair reveals its session; opening another pair
starts a sibling session.

Each canonical project root owns its live sessions, pending starts, and current
session. Starts and exits carry exact generation tokens so a late callback
cannot remove a newer session or a sibling. The public Logcat status is
aggregate: `running` while any session is live, `starting` while any start is
pending, and `stopped` otherwise.

Switching, hiding, stopping, and shutdown are separate lifecycle events.
Stop-all attempts every live session in the current root and reports refusals
without touching another root or pending start.

### Capture and package filtering

Each native session owns a device-wide reader:

```text
adb -s DEVICE logcat -b main,system,crash \
  -v threadtime,year,uid,printable '*:V'
```

Workbench resolves the selected package's UID and filters records inside
Neovim. It refreshes that mapping while the reader remains active. A package
reinstall can therefore change the UID without replacing the reader, session,
history, or filters.

The first implementation used `adb logcat --uid=UID`. Live testing showed two
problems with that boundary:

- Reinstalling the same application assigned it a new UID while the retained
  reader remained bound to the old one.
- `-T 200` chose the last 200 device-wide records before applying the UID
  filter, so it could return no application history even when older matching
  records existed.

The current reader is device-wide by default and uses the device's already
bounded Logcat buffers as its initial history. A configured positive
`initial_lines` value still adds an explicit `-T` cutoff. Records waiting for a
package mapping refresh have separate count and byte bounds.

### Presentation and hidden history

Native sessions keep independent buffers, filters, histories, and readers. One
native presenter uses one bottom dock and switches the buffer displayed there.
Showing a buffer that is already visible focuses its current window. If the
dock contains an unrelated buffer, Workbench leaves that window alone and
creates a new dock when needed.

Custom Logcat presenters own their own windows and are not required to use the
native dock.

When the last native window for a session is hidden, Workbench releases its
parsed records, buffer lines, and source index. Capture continues into bounded
rolling temporary storage. Each file is created with mode `0600` and unlinked
immediately after opening. Showing the session restores the newest retained
history. Stop, wipeout, or shutdown closes the descriptors.

Each session is bounded independently to 10,000 records, 4 MiB of raw record
text, and a 64 KiB logical line. Oversized lines are discarded through their
next newline before parsing resumes.

### User controls

- `:Android logcat` starts or reveals the selected application/device session.
- `:Android logcat sessions` selects an existing root-local session.
- `:Android logcat stop` stops the current session or cancels the newest pending
  start.
- `:Android logcat stop all` attempts to stop every live session in the current
  root.
- `S` opens the session picker from a native Logcat buffer.
- `q` hides the view without stopping capture; `s` stops that exact session.

The native window bar keeps the application, device, stream state, filters, and
common controls visible. `?` opens the complete shortcut list.

## Comparison with Android Studio

| Concern | Android Studio | Android Workbench |
| --- | --- | --- |
| Same device, different apps | Independent panels with package queries | Independent app-scoped sessions |
| Selecting a session | Reveals a panel; siblings keep running | Reveals a buffer; siblings keep running |
| Capture source | Device-wide per panel | Device-wide per session |
| Application association | Mutable query | Fixed package filter and session identity |
| Reader sharing | One reader per panel | One reader per session |
| Visible history | Bounded in memory per panel | Bounded in memory per session |
| Hidden history | Feature-gated rolling temporary files | Private rolling temporary files |
| Session count | No Logcat-specific tab cap found | No arbitrary session cap |
| Persisted state | Panel configuration, not messages | None |
| Split views | Supported | Not supported |

Workbench follows Studio's device-wide capture and client-side application
filtering model, but it deliberately exposes a smaller workflow.

## Costs and limits

Each live session owns an ADB reader, parser state, and bounded history. There
is no aggregate session cap because sessions are created explicitly and each is
bounded, but keeping more sessions alive still consumes more host and device
resources.

A clean-Neovim measurement fed 10,000 synthetic records of about 440 bytes into
each session. Four saturated sessions added 47.34 MiB of RSS; eight added 99.80
MiB. This measured Neovim memory, not device or ADB CPU use.

Workbench does not provide Studio's general query language, mutable package
queries, renamed tabs, split Logcat views, or persisted session configuration.
A deliberately shared Android UID can include records from sibling packages.
The experimental custom Logcat presenter contract remains subject to `0.x`
compatibility changes.

## Release verification

The `v0.2.0` live check ran two applications on one Android 16 emulator. Five
session switches kept both readers alive and reused the same dock. One
application restarted and was reinstalled with a different UID; its existing
session continued collecting records.

A hidden session retained 26 records and 3,424 raw bytes in an unlinked private
spool file. Stopping one session left its sibling active, stop-all removed the
remaining reader, and normal Neovim exit left no reader, package refresh,
Neovim process, or spool owner behind. The complete release checks are recorded
in [release verification](release-evidence.md).

## Sources

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
