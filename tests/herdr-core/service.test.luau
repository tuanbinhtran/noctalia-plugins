--!nonstrict
local h = require("../harness")
local Model = require("../../herdr-core/lib/model")
local Controller = require("../../herdr-core/lib/controller")
local protocol = require("../../herdr-core/lib/protocol")

local function fixture(enabled)
  local f = { now = 1000, commands = {}, notices = {}, json = {}, snapshots = {} }
  local host = {
    getConfig = function(key)
      return key == "notifications_enabled" and enabled
    end,
    getenv = function() return nil end,
    nowMs = function() return f.now end,
    commandExists = function(name) return name == "hc" or name == "python3" end,
    pluginDir = function() return "/tmp/noctalia/herdr-core" end,
    runStream = function(_, callback)
      f.onLine = callback
      return true
    end,
    runAsync = function(argv, callback)
      table.insert(f.commands, { argv = argv, callback = callback })
      return true
    end,
    state = {
      watch = function() end,
      set = function(key, value)
        if key == protocol.STATUS_KEY then
          table.insert(f.snapshots, value)
        end
      end,
    },
    json = { decode = function(line) return f.json[line] end },
    tr = function(key) return key end,
    notify = function(title, body) table.insert(f.notices, { title, body }) end,
  }
  f.model = Model.new()
  f.controller = Controller.new(host, f.model, protocol)
  f.controller:start()
  function f:line(raw, decoded)
    self.json[raw] = decoded
    self.onLine(raw)
  end
  function f:last()
    return self.snapshots[#self.snapshots]
  end
  return f
end

local f = fixture(true)
local localRun = { address = "t1", created_ms = 1, state = "live", turn = 1,
  status = { state = "done" }, status_ms = 1000 }
local remoteRun = { address = "box/t2", created_ms = 2, state = "live", turn = 1,
  status = { state = "blocked" }, status_ms = 2000 }
f:line('{"plugin":"alive"}', { plugin = "alive" })
f:line('{"seq":12,"terminals":[...]}', { seq = 12, terminals = { localRun, remoteRun } })
local key = f:last().view.attention[1].key
h.eq("An already completed run does not send a notification.", #f.notices, 0)
local oldQuery = f.commands[1]
f:line('{"plugin":"feed-down"}', { plugin = "feed-down" })
h.eq("Attention clears when the feed disconnects.", #f:last().view.attention, 0)
h.eq("feed down retains the terminal as stale", f.model:resolve(key).stale, true)
f:line('{"seq":1,"terminals":[...]}', { seq = 1, terminals = { localRun, remoteRun } })
h.eq("new snapshot does not overlap the previous inventory request", #f.commands, 1)
f.json['{"machines":[...]}'] = { machines = { { name = "box", state = "connected" } } }
oldQuery.callback({ exitCode = 0, stdout = '{"machines":[...]}', stderr = "" })
h.eq("A reply from the previous subscription cannot restore remote runs to Attention.", #f:last().view.attention, 1)
f.controller:update()
h.eq("The new subscription queries machines after the previous request completes.", #f.commands, 2)
f.json['{"machines":[]}'] = { machines = {} }
f.commands[2].callback({ exitCode = 0, stdout = '{"machines":[]}', stderr = "" })
f.now = 2000
f.controller:update()
h.eq("successful initial inventory does not trigger a second early poll", #f.commands, 2)
f:line('{"method":"event","params":{...}}', { method = "event", params = {
  seq = 2, type = "status", terminal = "t1",
  data = { status = { state = "blocked" }, records = {}, reported = true },
} })
h.eq("A newly blocked run sends one notification when enabled.", #f.notices, 1)
f.now = 28000
f.controller:update()
h.eq("missing supervisor heartbeat makes inventory stale", f:last().view.feed, "stale")
h.eq("heartbeat timeout does not drop the last row", f.model:resolve(key).stale, true)
f.now = 28100
f:line('{"plugin":"alive"}', { plugin = "alive" })
f:line('{"method":"heartbeat","params":{"seq":2}}', { method = "heartbeat", params = { seq = 2 } })
h.eq("same subscription can recover from delayed delivery", f:last().view.feed, "live")
f:line('{"plugin":"feed-down"}', { plugin = "feed-down" })
f:line('{"plugin":"alive"}', { plugin = "alive" })
f:line('{"method":"heartbeat","params":{"seq":2}}', { method = "heartbeat", params = { seq = 2 } })
h.eq("a disconnected Core requires a fresh snapshot", f:last().view.feed, "stale")

f = fixture(nil)
f:line('{"seq":1,"terminals":[...]}', { seq = 1, terminals = { localRun } })
f.json['{"machines":[]}'] = { machines = {} }
f.commands[1].callback({ exitCode = 0, stdout = '{"machines":[]}', stderr = "" })
f:line('{"method":"event","params":{...}}', { method = "event", params = {
  seq = 2, type = "status", terminal = "t1",
  data = { status = { state = "error" }, records = {}, reported = true },
} })
h.eq("A newly errored run sends no notification by default.", #f.notices, 0)

h.finish("herdr-core service")
