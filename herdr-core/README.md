# Herdr Core

A Noctalia bar widget and panel for [Herdr Core](https://github.com/herdrdev/herdr-core) (`hc`). The widget counts runs that need attention. The panel previews, opens, and launches runs.

## Requirements

- Noctalia v5 with plugin API 26 or later.
- `hc` 0.1.21 or later.
- Python 3 on `PATH`. The plugin uses it to supervise `hc events --json`.
- Optional: `herdr-app`, to open runs in the Herdr desktop app.

## Add the widget

Open **Settings** > **Bar** and add **Herdr Core**. To use the config file instead, add the widget to a bar:

```toml
[bar.main]
start = ["tuanbinhtran/herdr-core:bar"]
```

To open the panel, click the widget or run:

```sh
noctalia msg panel-toggle tuanbinhtran/herdr-core:panel
```

## Panel tabs

- **Attention** lists blocked, errored, and unseen done runs. **Mark seen** hides a done run in Noctalia. It does not change Core.
- **All** lists live terminals by machine. When a machine disconnects, its group shows **Stale** and its actions are off.
- **History** lists finished terminals that Core keeps, with the exit code, signal, or reason. When Core keeps many, History shows only the most recent finished runs.
- **New run** launches a saved `hc` template with a task and a working directory.

## Run actions

- **Preview** shows the screen and up to 40 lines of scrollback, capped at 16 KiB. It opens at the latest output. Each terminal row stays on one line, and a row wider than the panel ends with "…". An open preview replaces the run list, and the run's card stays above the preview.
- **Open** focuses the run's pane in `herdr-app`. If the run has no pane, **Open** shows it in a peek window without adding a tab. If `herdr-app` is not installed or not running, **Open** runs `hc attach` in Noctalia's terminal.
- **Open in terminal** always runs `hc attach` in Noctalia's terminal.

On Niri, the plugin focuses the `herdr-app` window when exactly one exists.

## Settings

- **Run alerts** sends a desktop notification when a run becomes blocked, errored, or done. It is off by default.
- **Always open in terminal** makes **Open** skip `herdr-app`. The plugin also skips `herdr-app` when Noctalia's environment sets `HC_SESSION` or `HC_SOCKET`, because the app might use a different Core.

## Run state

- Status comes from OSC 7501 reports. A terminal that sends no report shows **Unreported**.
- On Linux, `hc events` starts Core if Core is not running.
- Disabling the plugin stops its event watcher. Core and its terminals keep running.
- The plugin does not read the older Herdr TUI.

## Tests

Run these commands from the repository root:

```sh
./scripts/test.sh herdr-core
python3 -m unittest discover -s tests/herdr-core -p '*_test.py'
noctalia plugins lint herdr-core
```
