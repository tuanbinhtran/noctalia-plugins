# Herdr Core

A Noctalia bar widget and panel for [Herdr Core](https://github.com/herdrdev/herdr-core) (`hc`). Requires Noctalia v5 with plugin API 26, `hc` 0.1.21 or newer, and Python 3 on `PATH`.

Add **Herdr Core** in Settings → Bar, or include its entry in your existing bar configuration:

```toml
[bar.main]
start = ["tuanbinhtran/herdr-core:bar"]
```

Click the widget to open the panel, or run:

```sh
noctalia msg panel-toggle tuanbinhtran/herdr-core:panel
```

- **Attention:** Blocked, errored and unseen done runs. **Mark seen** dismisses a completion in Noctalia, not in Core.
- **All:** Live terminals grouped by machine, with disconnected groups marked stale. **Open** focuses the existing `herdr-app` pane or peeks at an unplaced run. If the app is absent, it attaches in Noctalia's configured terminal. **Open in terminal** always attaches there.
- **History:** Exits retained by Core. **Preview** reads the screen and up to 40 scrollback lines on demand, capped at 16 KiB.
- **New run:** Launch a saved local `hc` template with a task and working directory.

The app and plugin share live terminals when they use the same Core. On Niri, the plugin can focus the single existing Herdr app window. Enable **Always open in terminal** in plugin settings to skip app routing; an explicit `HC_SESSION` or `HC_SOCKET` in Noctalia's environment also skips it. The plugin does not monitor the older Herdr TUI.

Desktop alerts are off by default. Run state comes from OSC 7501 reports; terminals without one show **Unreported**. The event watcher may start Core on Linux. Disabling the plugin stops only its watcher, not Core or its terminals.

## Tests

```sh
./scripts/test.sh herdr-core
python3 -m unittest discover -s tests/herdr-core -p '*_test.py'
noctalia plugins lint herdr-core
```
