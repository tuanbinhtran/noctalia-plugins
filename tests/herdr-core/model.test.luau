--!nonstrict
local h = require("../harness")
local Model = require("../../herdr-core/lib/model")

local function terminal(address, status, fields)
  local t = { address = address, created_ms = 10, state = "live", pid = 99, turn = 1 }
  if status then
    t.status = { state = status }
    t.status_ms = 50
  end
  for k, v in pairs(fields or {}) do
    t[k] = v
  end
  return t
end

local function initial(m, seq, ...)
  return m:apply({ seq = seq, terminals = { ... } }, 60)
end

local function event(m, seq, kind, address, data)
  return m:apply({ method = "event", params = {
    seq = seq, type = kind, terminal = address, data = data,
  } }, 60 + seq)
end

local function status(m, seq, address, word)
  return event(m, seq, "status", address, { status = { state = word }, records = {}, reported = true })
end

local m = Model.new()
local done = terminal("t1", "done")
h.eq("initial snapshot does not alert", initial(m, 20, done), {})
local key = m:view().attention[1].key
h.eq("attention lists the done run", m:view().attention[1].address, "t1")
m:markSeen(key)
h.eq("mark seen removes the run from attention", #m:view().attention, 0)
m:setFeedDown()
initial(m, 1, done)
h.eq("mark seen survives a reconnect with a lower sequence", #m:view().attention, 0)
status(m, 2, "t1", "working")
local notices = status(m, 3, "t1", "done")
h.eq("second completion becomes visible", m:view().attention[1].address, "t1")
h.eq("second completion alerts once", #notices, 1)
m:markSeen(key)
event(m, 4, "turn", "t1", { turn = 2, state = "done" })
h.eq("same episode turn update does not undo dismissal", #m:view().attention, 0)
h.eq("duplicate status event never alerts", status(m, 4, "t1", "blocked"), {})
h.eq("duplicate status cannot make the badge urgent", m:view().tone, "neutral")
h.eq("missed snapshot never alerts", m:apply({ method = "missed", params = {
  seq = 15, terminals = { terminal("t1", "done", { turn = 3, status_ms = 88 }) },
} }, 101), {})
h.eq("new turn during missed window appears in attention", #m:view().attention, 1)
m:markSeen(key)
event(m, 16, "removed", "t1", {})
event(m, 17, "created", "t1", terminal("t1", "done", { created_ms = 400 }))
h.eq("old identity cannot resolve a reused address", m:resolve(key), nil)
h.eq("old dismissal cannot hide a newer run", #m:view().attention, 1)

m = Model.new()
initial(m, 10, terminal("t1", "working", { turn = 0 }))
status(m, 11, "t1", "done")
m:markSeen(m:view().attention[1].key)
m:setFeedDown()
initial(m, 1, terminal("t1", "done", { turn = 1, status_ms = 100 }))
h.eq("mark seen survives a disconnect before the turn event", #m:view().attention, 0)
status(m, 2, "t1", "working")
status(m, 3, "t1", "done")
h.eq("later done still appears after recovery", #m:view().attention, 1)

m = Model.new()
initial(m, 1, terminal("t1", nil), terminal("box/t2", "blocked"), terminal("t3", "paused"))
h.eq("attention skips runs on unconfirmed machines", #m:view().attention, 0)
m:setMachines({ { name = "box", state = "connected" } })
local remote = m:view().attention[1].key
h.eq("remote attention uses its full address", m:resolve(remote).address, "box/t2")
local previousView = m:view()
m:setMachines({ { name = "box", state = "connected" } })
h.eq("identical machine poll does not force a UI publish", m:view() == previousView, true)
m:setMachines(nil)
h.eq("failed machine inventory retains last remote row", m:resolve(remote).stale, true)
h.eq("stale remote drops out of attention", #m:view().attention, 0)
m:setMachines({})
h.eq("removed machine loses its row", m:resolve(remote), nil)
h.eq("unreported and unknown remain live and neutral", m:view().tone, "neutral")

m = Model.new()
local kept = terminal("t4", "blocked", { keep = true })
initial(m, 1, kept)
local keptKey = m:view().attention[1].key
event(m, 2, "lost", "t4", { reason = "signaled", signal = 15 })
h.eq("kept terminal stays visible as recovering", m:resolve(keptKey).recovering, true)
h.eq("a recovering terminal stays out of history", #m:view().history, 0)
h.eq("recovering terminal does not demand attention", #m:view().attention, 0)
event(m, 3, "restarted", "t4", terminal("t4", nil, { keep = true, pid = 120 }))
h.eq("restarted shell leaves recovering state", m:resolve(keptKey).recovering, false)
event(m, 4, "finished", "t4", { reason = "exited", exit_code = 7, finished_ms = 900 })
h.eq("exit without done appears in history", m:view().history[1].exitCode, 7)
h.eq("an exit is not a done episode", #m:view().attention, 0)

h.finish("herdr-core model")
