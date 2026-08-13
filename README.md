# Android Workbench

Android Workbench is an extensible Android development toolkit for Neovim,
focused on Gradle, app deployment, emulators, and Logcat.

## What it does

- Discovers Android applications and variants through the project's own Gradle
  wrapper and remembers the selected app, variant, and device per project.
- Builds, installs, launches, and force-stops the selected app.
- Lists local AVDs and starts, Cold Boots, or stops the one you choose.
- Runs registered Gradle tasks and keeps their output available.
- Keeps separate Logcat sessions alive for different apps and devices.
- Sends recognized compiler, Lint, AAPT, and AGP errors to quickfix.

## Scope

Workbench handles Android and Gradle workflows. Kotlin and Java language
support, formatting, test frameworks, and debugging remain outside its scope.

It includes native pickers, task output, quickfix integration, emulator
management, and Logcat. Optional Snacks, Telescope, Overseer, and diagnostic
integrations are configured separately. Workbench does not define global
mappings, override `vim.ui.select`, or configure Trouble.

## Requirements

- Neovim 0.12.4
- An executable Unix `gradlew`, plus the JDK and Android SDK required by the
  project
- `adb` on `PATH` for device actions and Logcat
- Android Emulator on `PATH` for AVD management

macOS and Linux are tested. Windows is not supported yet because Workbench has
no tested `gradlew.bat` path.

The release tests cover Gradle 7.3.3 with AGP 7.1.3 and Gradle 9.1.0 with AGP
9.0.1 on Java 17. Other combinations may work, but have not passed this
project's release gate. Exact results are in
[docs/release-evidence.md](docs/release-evidence.md).

## Install

With [`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack):

```lua
vim.pack.add {
  {
    src = 'https://github.com/gvanderclay/android-workbench.nvim',
    version = vim.version.range('0.3'),
  },
}
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'gvanderclay/android-workbench.nvim',
  version = '^0.3.0',
}
```

You do not need to call `setup()`. The plugin registers `:Android` and loads
the rest when you use it.

## Use it

Open Neovim inside an Android project and check the local tools:

```vim
:checkhealth android_workbench
```

Then open the action picker:

```vim
:Android
```

Choose `Run`. Workbench selects the target or device automatically when only one
is available; otherwise it opens a picker. It remembers both choices for the
project. A selected stopped AVD is started and awaited automatically.

Gradle actions run project-controlled code. Workbench asks for Neovim project
trust immediately before each invocation of the project's wrapper.

The commands are grouped by job:

- Target: `target app`, `target variant`, `target device`
- App: `build`, `run`, `stop`
- Emulator: `emulator`, `emulator start`, `emulator stop`
- Gradle: `gradle`, `output`
- Logs: `logcat`, `logcat sessions`, `logcat stop`, `logcat stop all`
- Project: `status`, `refresh`, `cancel`

Prefix each one with `:Android`. See `:help android-workbench-commands` for
their exact behavior.

## Logcat

Logcat sessions belong to an app and device pair. Starting another session
does not stop the ones already running. Use `:Android logcat sessions`, or
press `S` in the Logcat window, to switch between them.

The native view keeps a bounded history while hidden. A session survives app
process restarts and reinstalls, and stopping one session leaves its siblings
alone.

Press `?` in the Logcat window to see every shortcut. Common controls:

| Key            | Action                              |
| -------------- | ----------------------------------- |
| `S`            | Switch sessions                     |
| `p`            | Pause or resume drawing new records |
| `f`            | Follow the newest record            |
| `c`            | Clear the local view                |
| `l`            | Set the minimum log level           |
| `t`            | Filter by tag                       |
| `/`            | Filter by message                   |
| `x`            | Reset filters                       |
| `<CR>` or `gf` | Open a Kotlin or Java stack frame   |

## Configuration

`setup()` is optional and only stores configuration. It does not inspect a
project, ask for trust, query ADB, enumerate AVDs, or run Gradle.

Workbench does not define global mappings. For example:

```lua
vim.keymap.set('n', '<leader>aa', '<cmd>Android<CR>', {
  desc = 'Android actions',
})
```

This setup replaces only the picker and Gradle runner:

```lua
require('android_workbench').setup {
  ports = {
    picker = require('android_workbench.integrations.snacks').new(),
    runner = require('android_workbench.integrations.overseer').new(),
  },
}
```

Each integration is optional. Omitted ports keep their native behavior, and
Workbench loads Snacks, Telescope, or Overseer only when you select that
integration. Snacks must be installed with its picker enabled. The diagnostic
projection and adapter contracts are documented in
`:help android-workbench-adapters`.

## Help

- `:help android-workbench` is the full user and adapter reference.
- `:checkhealth android_workbench` checks Neovim, the project wrapper, ADB, and
  the emulator tools used by the current project.
- The [contribution guide](CONTRIBUTING.md) explains useful bug reports and
  clean-Neovim reproductions before opening a
  [GitHub issue](https://github.com/gvanderclay/android-workbench.nvim/issues).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[documentation map](docs/README.md) before changing public behavior.

Run the standalone checks with:

```sh
make test
make test-format
```

The real Gradle and optional-adapter fixtures are separate because they use the
network and local Android SDK:

```sh
make test-integration
```

## Releases

See
[GitHub Releases](https://github.com/gvanderclay/android-workbench.nvim/releases)
for tagged versions and [CHANGELOG.md](CHANGELOG.md) for their changes. Android
Workbench is still pre-1.0 and is not in a plugin registry. A minor `0.x`
release may contain breaking changes. Experimental adapter contracts may also
change without a compatibility bridge.

Android Workbench is licensed under the [MIT License](LICENSE).
