--!nonstrict
local h = require("../harness")
local Actions = require("../../herdr-core/lib/actions")
local protocol = require("../../herdr-core/lib/protocol")

local function fixture()
  local f = { commands = {}, replies = {}, results = {}, terminals = {}, env = {}, appInstalled = true }
  f.row = { key = "run", address = "box/t7", state = "live", stale = false, recovering = false }
  local host = {
    commandExists = function(name) return name ~= "herdr-app" or f.appInstalled end,
    getenv = function(key) return f.env[key] end,
    getConfig = function(key) return key == "open_in_terminal_only" and f.terminalOnly end,
    runAsync = function(argv, callback)
      if f.rejectQueue then return false end
      table.insert(f.commands, { argv = argv, callback = callback })
      return true
    end,
    runInTerminal = function(command)
      table.insert(f.terminals, command)
      return true
    end,
    json = { decode = function(token) return f.replies[token] end },
    expandPath = function(path) return path == "~" and "/home/test" or path end,
    tr = function(key, args)
      return args and args.error and `{key}: {args.error}` or key
    end,
    fileInfo = function() return { isDir = true } end,
  }
  f.actions = Actions.new(host, function(key)
    return f.row and f.row.key == key and f.row or nil
  end, function(result)
    table.insert(f.results, result)
  end, protocol.quote)
  function f:dispatch(id, action, args)
    local req = args or {}
    req.action = action
    req.id = id
    self.actions:dispatch(req)
  end
  function f:reply(n, decoded, code, stderr)
    local token = tostring(n)
    self.replies[token] = decoded
    self.commands[n].callback({ exitCode = code or 0, stdout = token, stderr = stderr or "" })
  end
  function f:last()
    return self.results[#self.results]
  end
  return f
end

local placed = { spaces = { { tabs = { { terminals = { { terminal = "box/t7", pane = "p7" } } } } } } }
local empty = { spaces = {} }
local f = fixture()
f:dispatch("open-1", "open", { key = "run" })
f:reply(1, placed)
h.eq("placed run focuses its current app pane", f.commands[2].argv,
  { "herdr-app", "do", "pane.focus", "--terminal", "box/t7" })
f:reply(2, { ok = true })
h.eq("app acceptance tells panel to close before raise", f:last().kind, "open-app")
h.eq("app success does not open another viewer", #f.terminals, 0)
h.eq("app not raised before panel acknowledgement", #f.commands, 2)
f:dispatch("ack-1", "raise-app", { openedId = "open-1" })
f:dispatch("ack-2", "raise-app", { openedId = "open-1" })
h.eq("raise acknowledgement is single-use", #f.commands, 3)
h.eq("raise uses the same desktop app", f.commands[3].argv, { "herdr-app" })

f = fixture()
f.env.NIRI_SOCKET = "/tmp/niri.test.sock"
f:dispatch("niri-open", "open", { key = "run" })
f:reply(1, placed)
f:reply(2, { ok = true })
f:dispatch("niri-ack", "raise-app", { openedId = "niri-open" })
h.eq("after close, Niri discovers the exact app window", f.commands[3].argv,
  { "niri", "msg", "--json", "windows" })
f:reply(3, { { id = 8, app_id = "herdr-app" }, { id = 12, app_id = "terminal", title = "Herdr" } })
h.eq("Niri focuses verified app ID rather than a matching title", f.commands[4].argv,
  { "niri", "msg", "action", "focus-window", "--id", "8" })
f:reply(4, nil)
h.eq("successful compositor focus needs no app relaunch", #f.commands, 4)

f = fixture()
f:dispatch("open-2", "open", { key = "run" })
f:reply(1, empty)
h.eq("unplaced terminal peeks rather than creates a tab", f.commands[2].argv,
  { "herdr-app", "do", "terminal.peek", "--terminal", "box/t7" })
f:reply(2, { error = "no running terminal" })
h.eq("app rejection is reported even with zero exit status", type(f:last().error), "string")
h.eq("app rejection never opens a terminal viewer", #f.terminals, 0)

f = fixture()
f:dispatch("open-reject-path", "open", { key = "run" })
f:reply(1, empty)
f:reply(2, nil, 1, "No such file or directory while handling an app command")
h.eq("unrelated ENOENT is not app socket absence", #f.terminals, 0)

f = fixture()
f.rejectQueue = true
f:dispatch("open-busy-queue", "open", { key = "run" })
h.eq("rejected subprocess submission does not open a second viewer", #f.terminals, 0)

f = fixture()
f:dispatch("open-3", "open", { key = "run" })
f:reply(1, nil, 2, "herdr-app: no Herdr window at /tmp/herdr-app.sock: No such file or directory (os error 2)\n")
h.eq("known missing app attaches to the same remote terminal", f.terminals[1], "hc attach 'box/t7'")

f = fixture()
f.env.HC_SESSION = "isolated-core"
f:dispatch("open-4", "open", { key = "run" })
h.eq("explicit Core selection does not route by colliding app address", #f.commands, 0)
h.eq("override still attaches to selected Core", f.terminals[1], "hc attach 'box/t7'")

f = fixture()
f:dispatch("open-5", "open", { key = "run" })
f.row = { key = "replacement", address = "box/t7", state = "live" }
f:reply(1, placed)
h.eq("reused addresses cannot redirect a pending click", #f.commands, 1)
h.eq("reused addresses cannot silently attach", #f.terminals, 0)

f = fixture()
f:dispatch("open-stale-layout", "open", { key = "run" })
f.row = nil
f:reply(1, placed)
h.eq("stale row after app lookup returns an unavailable result", f:last().error, "action.unavailable")
f.row = { key = "run", address = "box/t7", state = "live" }
f:dispatch("open-after-stale-layout", "open", { key = "run" })
h.eq("stale lookup releases the run action guard", #f.commands, 2)

f = fixture()
f:dispatch("open-stale-action", "open", { key = "run" })
f:reply(1, placed)
f.row = nil
f:reply(2, { ok = true })
h.eq("stale row after app action returns an unavailable result", f:last().error, "action.unavailable")
f.row = { key = "run", address = "box/t7", state = "live" }
f:dispatch("open-after-stale-action", "open", { key = "run" })
h.eq("stale app response releases the run action guard", #f.commands, 3)

f = fixture()
f:dispatch("preview-1", "preview", { key = "run" })
f:dispatch("cancel-1", "cancel-preview")
f:reply(1, { complete = true, text = "private output from previous selection" })
for _, result in ipairs(f.results) do
  h.eq("cancelled output never publishes", result.preview, nil)
end

f = fixture()
f:dispatch("preview-ok", "preview", { key = "run" })
f:reply(1, { complete = true, text = "A\27]0;title\27\\visible\7!\r\n" })
h.eq("preview does not consume visible output between OSC ST and later BEL", f:last().preview, "Avisible!\n")
f:dispatch("preview-tail", "preview", { key = "run" })
f:reply(2, { complete = false, text = string.rep("€", 6000) })
h.eq("preview truncates only on complete UTF-8 characters", #f:last().preview, 16383)
h.eq("truncated preview retains valid UTF-8", utf8.len(f:last().preview), 5461)
h.eq("preview reports partial Core output", f:last().incomplete, true)
f:dispatch("preview-error", "preview", { key = "run" })
local stderr = '{"error":{"kind":"not_found","message":"remote terminal became unavailable"}}'
f.replies[stderr] = { error = { kind = "not_found", message = "remote terminal became unavailable" } }
f:reply(3, nil, 3, stderr)
h.eq("preview reports Core reason without its JSON envelope", f:last().error,
  "action.command_failed: remote terminal became unavailable")

f = fixture()
local template = { name = "reviewer", description = "Review code", command = "agent" }
f:dispatch("templates-1", "templates")
f:reply(1, { templates = { template } })
f:dispatch("run-1", "launch", { template = "reviewer", cwd = "/tmp", task = "Review the code" })
f:reply(2, { templates = {} })
h.eq("deleted template cannot be interpreted as an executable", #f.commands, 2)
h.eq("deleted template gives the user an error", type(f:last().error), "string")

f = fixture()
local broken = { name = "bad", description = "", command = "", error = "missing command" }
f:dispatch("templates-valid", "templates")
f:reply(1, { templates = { broken, template } })
h.eq("broken saved templates are not launch choices", #f:last().templates, 1)
f:dispatch("run-broken", "launch", { template = "bad", cwd = "/tmp", task = "Review the code" })
f:reply(2, { templates = { broken } })
h.eq("invalidated template cannot reach hc run", #f.commands, 2)

f = fixture()
f:dispatch("templates-2", "templates")
f:reply(1, { templates = { template } })
f:dispatch("run-2", "launch", { template = "reviewer", cwd = "/tmp", task = "--outlive-parent" })
f:reply(2, { templates = { template } })
h.eq("flag-like task remains one literal task operand", f.commands[3].argv,
  { "hc", "run", "--json", "--bg", "--no-parent", "--cwd", "/tmp", "--", "reviewer", " --outlive-parent" })
f:reply(3, { address = "t8", first_message = { sent = false, reason = "Agent did not become ready" } })
h.eq("start retains address when task delivery fails", f:last().address, "t8")
h.eq("user can distinguish launch from task delivery", type(f:last().warning), "string")

f = fixture()
local request = { template = "reviewer", cwd = "/tmp", task = "Run once" }
f:dispatch("launch-once", "launch", table.clone(request))
f:dispatch("launch-again", "launch", table.clone(request))
h.eq("rapid launch clicks have one pending validation", #f.commands, 1)

h.finish("herdr-core actions")
