# Herdr Core for Noctalia

## Scope

`tuanbinhtran/herdr-core` is a Noctalia v5 bar widget, attached panel, and background service for Herdr Core (`hc`). It shows which runs need attention and opens runs in `herdr-app` or Noctalia's terminal. It also previews output, shows recent exits, and launches saved local templates. Target the tested interfaces of Noctalia 5.3 and `hc` 0.1.21. The plugin needs `hc` and Python 3 on `PATH`; Python is used only to supervise the event stream.

The plugin uses the Core selected by Noctalia's environment, including `HC_SESSION` and `HC_SOCKET` when set. It does not discover other local Core sessions or configure remote machines. `hc events` can start Core when none is listening on Linux. Disabling or reloading the plugin must stop its watcher, not Core or any managed terminals.

## Bar and panel

- **Bar:** Badge counts reachable terminals in Attention. Blocked and error take precedence over unseen done, then working, then neutral. Stale data must not generate an attention indication; show a disconnected indicator instead when the local feed is stale.
- **Attention:** Open here by default. Group blocked and errored live runs ahead of unseen done runs; sort by newest status change within each group. **Mark seen** dismisses a done episode from Attention without modifying Core. Blocked and errored live rows stay until their reported status changes. Optional alerts (off by default) fire on observed entries into blocked, error, or done; never replay alerts from initial, missed, or reconnect snapshots. Alerts include the terminal label and status, not output or task text.
- **All:** List live terminals grouped by machine, with parent–child nesting where both rows are visible in that group. Show the parent address for a child whose parent is elsewhere. Use name, title, or address for the primary label. A terminal without a reported root status is **Unreported**, not **Ready**; an unknown status is displayed without being counted as attention. Disconnected remote groups remain visible with a stale label and disabled actions. If a machine is removed from Core, remove its group.
- **History:** Show the finished records retained by Core, newest finish first. Show exit code, signal, or reason when supplied. An agent's done status does not imply its process exited. Do not maintain a separate archive; a lost kept terminal belongs in All as recovering, not in History.

Live rows open with **Open** or **Open in terminal**, including machine-qualified addresses. **Open** focuses the run's pane in `herdr-app`. It peeks at a run that has no pane. When `herdr-app` is not installed or not running, **Open** runs `hc attach <address>` in Noctalia's terminal. **Open in terminal** always runs `hc attach <address>`. The plugin skips `herdr-app` when Noctalia's environment sets `HC_SESSION` or `HC_SOCKET` or when the **Always open in terminal** setting is on. On Niri, the plugin focuses the single `herdr-app` window. The plugin takes the attach address from service state, not a display label. It quotes the address safely for `runInTerminal`. It closes the panel when the terminal launch is accepted. The attached session can detach without stopping the run.

**Preview** reads an explicitly selected live or finished terminal via `hc read --json --lines 40 <address>`. Render the returned screen and up to 40 scrollback lines as plain text, capped at 16 KiB on a UTF-8 boundary. Indicate incomplete or truncated output. Never fetch previews in the background, write them to disk, or reuse a response after the selected run changes.

**New run** lists valid `hc templates --json` entries and shows the saved template description. Require a template, task, and local working directory (default: home). Revalidate the selected template before sending a detached launch to `hc`, with argv rather than a shell command string. Task text is an argument, not shell input. Noctalia offers no executable field and does not construct or interpret the saved command. In `hc` 0.1.21, template names share the executable operand: revalidation rejects a missing template, but deletion between validation and launch can still hit Core's executable fallback. Do not retry a launch automatically; show the returned error or the new terminal address. Follow the event stream for its status rather than inventing a successful state. Remote launches, raw shell commands, agent input and approvals, and stop/delete controls are out of scope.

## State and transport

The Luau service owns the action requests, terminal index, and compact snapshot shared by bar and panel. Terminal identity is the Core address plus its creation timestamp; compare completion episodes using the run's turn and status transitions. Keep seen markers in memory for the plugin lifetime, including reconnects. A new done episode must be eligible for Attention even if the previous one was acknowledged.

Use one `noctalia.runStream` supervisor per service lifetime. A bundled standard-library Python helper owns one `hc events --json` child at a time. It emits a feed-down marker on EOF or after 45 seconds without a line, terminates and reaps the old watcher, and retries with bounded backoff. The helper exits on service cancellation or loss of its stdout pipe and cleans up its child. Supervision lives outside Luau because Noctalia 5.3 exposes stdout lines but no process exit or stop callback for `runStream`. Use `noctalia.pluginDir()` for the helper path and quote it for the static launch command. Emit a supervisor heartbeat independent of the child; if the supervisor cannot start or stops reporting, show a connection error rather than an empty inbox.

Apply the initial snapshot, ordered updates, and replacement snapshots after `missed` or reconnect. Sequence numbers reset across Core restarts: take each replacement snapshot as authoritative and reject older events in that subscription. Keep the last known rows visibly stale while disconnected; do not enable actions on them until a fresh snapshot. Process topology, status, and lifecycle updates; skip unrelated events without disturbing sequence tracking. Publish only when a displayed value changes.

Poll `hc machine ls --json` at most every 15 seconds while the event feed is live, with an immediate check after a fresh subscription. Machine connectivity is separate from terminal events. Show a remote group as stale until its machine state is confirmed connected; failed machine queries do not make remote rows actionable. The plugin does not contact individual hosts itself. Action errors are shown in the panel and do not replace the feed state.

## Verification

Cover state with fixtures for initial snapshots, status changes, a second completion after marking seen, snapshot replacement and sequence reset, terminal address reuse, remote staleness, kept-terminal loss/recovery, and exits without a prior done status. Exercise the supervisor with a fake child for EOF, a stalled stream, and cancellation; check that no extra watcher remains. Check template-revalidation failure and stale preview callbacks without touching the user's live runs.

Lint the installed plugin and exercise its bar and panel in Noctalia against an isolated `HC_SESSION`: see a status transition without refresh, mark a completion seen, preview then attach, launch a saved template, and verify reload/disable leaves the managed run alive. Separately verify remote attach and stale rendering against a configured test machine.

## References

- [Upstream Herdr plugin](https://github.com/noctalia-dev/community-plugins/tree/main/herdr)
- [Herdr Core v0.1.21 API](https://github.com/herdrdev/herdr-core/blob/v0.1.21/schema/README.md) and [commands](https://github.com/herdrdev/herdr-core/blob/v0.1.21/docs/commands.md)
- [Noctalia 5.3 runtime API](https://docs.noctalia.dev/noctalia/v5.3.0/plugins/development/runtime-api/)
