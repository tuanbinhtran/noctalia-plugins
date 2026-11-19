--!nonstrict
-- The bar and panel share the cached view. Do not mutate its rows.
local Model = {}
Model.__index = Model

local ALERT_STATUS = { blocked = true, error = true, done = true }
local URGENT_STATUS = { blocked = true, error = true }

local function num(value)
  if type(value) == "number" then
    return value
  end
  return nil
end

local function text(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function machineOf(address)
  local slash = string.find(address, "/", 1, true)
  if slash then
    return string.sub(address, 1, slash - 1)
  end
  return ""
end

-- Pad digit runs so t2 sorts before t10.
local function naturalKey(value)
  return (string.gsub(value, "%d+", function(digits)
    return string.rep("0", math.max(0, 12 - #digits)) .. digits
  end))
end

-- Core reuses addresses, so include creation time in the terminal key.
local function record(t)
  local created = num(t.created_ms) or 0
  local status = nil
  if type(t.status) == "table" then
    status = text(t.status.state)
  end
  return {
    key = `{t.address}/{created}`,
    address = t.address,
    machine = machineOf(t.address),
    parent = text(t.parent),
    name = text(t.name),
    title = text(t.title),
    createdMs = created,
    sortKey = naturalKey(t.address),
    state = if t.state == "finished" then "finished" else "live",
    status = status,
    statusAt = num(t.status_ms),
    finishedAt = num(t.finished_ms),
    exitCode = num(t.exit_code),
    signal = num(t.signal),
    reason = text(t.reason),
    keep = t.keep == true,
    pid = num(t.pid),
    ep = nil,
  }
end

-- A snapshot can show a done episode that happened while the feed was down.
-- Snapshots never send notifications.
local function adopt(rec, prev, turn)
  local ep
  if prev == nil then
    ep = { episode = if rec.status == "done" then 1 else 0, seen = 0 }
  else
    ep = prev.ep
    if rec.status == "done" then
      local advanced = rec.statusAt ~= nil and ep.statusMs ~= nil and rec.statusAt > ep.statusMs
      if prev.status ~= "done" or turn ~= ep.turn or advanced then
        ep.episode += 1
      end
    end
  end
  ep.turn = turn
  ep.statusMs = rec.statusAt
  rec.ep = ep
end

local function recovering(rec)
  return rec.state == "live" and rec.keep and rec.pid == nil and rec.reason ~= nil
end

function Model.new()
  return setmetatable({
    feed = "loading",
    expectSnapshot = true,
    seq = 0,
    terms = {},
    states = {},
    known = {}, -- Machines in this subscription's last successful inventory.
    cache = nil,
    index = nil,
  }, Model)
end

function Model:reachable(rec)
  return self.feed == "live" and (rec.machine == "" or self.states[rec.machine] == "connected")
end

local function replace(self, terminals)
  local old = self.terms
  local terms = {}
  for _, t in terminals do
    if type(t) == "table" and type(t.address) == "string" then
      local rec = record(t)
      local prev = old[rec.address]
      if prev ~= nil and prev.key ~= rec.key then
        prev = nil
      end
      adopt(rec, prev, num(t.turn) or 0)
      terms[rec.address] = rec
    end
  end
  self.terms = terms
  self.cache = nil
end

local function place(self, t, address)
  if type(t) ~= "table" then
    return
  end
  if type(t.address) ~= "string" then
    if type(address) ~= "string" then
      return
    end
    t = setmetatable({ address = address }, { __index = t })
  end
  local rec = record(t)
  local prev = self.terms[rec.address]
  if prev ~= nil and prev.key ~= rec.key then
    prev = nil
  end
  adopt(rec, prev, num(t.turn) or 0)
  self.terms[rec.address] = rec
  self.cache = nil
end

local function status(self, rec, data, nowMs, notices)
  local word = nil
  if type(data.status) == "table" then
    word = text(data.status.state)
  end
  local before = rec.status
  if word == before then
    return
  end
  rec.status = word
  rec.statusAt = nowMs
  rec.ep.statusMs = nil -- Status events carry no Core timestamp.
  if before == "working" then
    -- Core increments `turn` before it sends the status and turn events.
    -- Predict the increment so a reconnect between those events keeps Mark seen.
    rec.ep.turn += 1
  end
  if word == "done" then
    rec.ep.episode += 1
  end
  self.cache = nil
  if
    ALERT_STATUS[word]
    and rec.state == "live"
    and not recovering(rec)
    and self:reachable(rec)
  then
    table.insert(notices, {
      key = rec.key,
      label = rec.name or rec.title or rec.address,
      status = word,
    })
  end
end

local function applyEvent(self, kind, address, data, nowMs, notices)
  if kind == "created" or kind == "restarted" then
    place(self, data, address)
    return
  end
  local rec = if type(address) == "string" then self.terms[address] else nil
  if rec == nil then
    return
  end
  if kind == "removed" then
    self.terms[address] = nil
    self.cache = nil
    return
  end
  if type(data) ~= "table" then
    return
  end
  if kind == "status" then
    status(self, rec, data, nowMs, notices)
  elseif kind == "turn" then
    rec.ep.turn = num(data.turn) or rec.ep.turn
  elseif kind == "title" then
    rec.title = text(data.title)
    self.cache = nil
  elseif kind == "keep" then
    rec.keep = data.keep == true
    self.cache = nil
  elseif kind == "lost" then
    rec.reason = text(data.reason)
    rec.exitCode = num(data.exit_code)
    rec.signal = num(data.signal)
    rec.finishedAt = nil
    rec.pid = nil
    self.cache = nil
  elseif kind == "finished" then
    rec.state = "finished"
    rec.reason = text(data.reason)
    rec.exitCode = num(data.exit_code)
    rec.signal = num(data.signal)
    rec.finishedAt = num(data.finished_ms)
    rec.status = nil
    rec.statusAt = nil
    rec.pid = nil
    self.cache = nil
  end
end

function Model:apply(frame, nowMs)
  local notices = {}
  if type(frame) ~= "table" then
    return notices
  end
  local method = frame.method
  if method == nil then
    if self.expectSnapshot and type(frame.seq) == "number" and type(frame.terminals) == "table" then
      self.expectSnapshot = false
      self.feed = "live"
      self.seq = frame.seq
      self.states = {} -- Each subscription confirms machines again.
      self.known = {}
      replace(self, frame.terminals)
    end
  elseif method == "missed" then
    local params = frame.params
    if
      not self.expectSnapshot
      and type(params) == "table"
      and type(params.seq) == "number"
      and type(params.terminals) == "table"
    then
      self.seq = params.seq
      replace(self, params.terminals)
    end
  elseif method == "event" then
    local params = frame.params
    if
      not self.expectSnapshot
      and type(params) == "table"
      and type(params.seq) == "number"
      and params.seq > self.seq
    then
      self.seq = params.seq
      applyEvent(self, params.type, params.terminal, params.data, nowMs, notices)
    end
  end
  return notices
end

-- A watchdog timeout keeps the Core subscription. A matching Core heartbeat resumes the live feed.
function Model:setWatchdogStale()
  if self.feed ~= "stale" then
    self.feed = "stale"
    self.cache = nil
  end
  self:setMachines(nil)
end

function Model:resumeWatchdogFeed()
  if self.expectSnapshot then
    return false
  end
  if self.feed ~= "live" then
    self.feed = "live"
    self.cache = nil
  end
  return true
end

function Model:setFeedDown()
  if self.feed ~= "stale" then
    self.feed = "stale"
    self.cache = nil
  end
  self.expectSnapshot = true
end

-- A failed inventory leaves remote rows visible but stale.
-- Remove rows only when a successful inventory no longer lists their machine.
function Model:setMachines(machines)
  local old = self.states
  if machines == nil then
    for _, state in old do
      if state == "connected" then
        self.cache = nil
        break
      end
    end
    self.states = {}
    return
  end
  local states = {}
  for _, machine in machines do
    if type(machine) == "table" and type(machine.name) == "string" then
      states[machine.name] = machine.state
    end
  end
  local changed = false
  for name in self.known do
    if states[name] == nil then
      changed = true
      for address, rec in self.terms do
        if rec.machine == name then
          self.terms[address] = nil
        end
      end
    end
  end
  local known = {}
  for name, state in states do
    known[name] = true
    if self.known[name] == nil or (state == "connected") ~= (old[name] == "connected") then
      changed = true
    end
  end
  for name, state in old do
    if states[name] == nil and state == "connected" then
      changed = true
    end
  end
  if changed then
    self.cache = nil
  end
  self.known = known
  self.states = states
end

function Model:markSeen(key)
  for _, rec in self.terms do
    if rec.key == key then
      if rec.status == "done" and rec.ep.seen < rec.ep.episode then
        rec.ep.seen = rec.ep.episode
        self.cache = nil
        return true
      end
      return false
    end
  end
  return false
end

function Model:resolve(key)
  self:view()
  return self.index[key]
end

local function newestFirst(a, b)
  local at = a.statusAt or 0
  local bt = b.statusAt or 0
  if at ~= bt then
    return at > bt
  end
  return a.key < b.key
end

local function attentionRank(row)
  return if URGENT_STATUS[row.status] then 0 else 1
end

local function creationOrder(a, b)
  if a.createdMs ~= b.createdMs then
    return a.createdMs < b.createdMs
  end
  return a.sortKey < b.sortKey
end

-- Nest a row under its parent only when both rows are in the same group and no cycle forms.
-- Otherwise show the parent address as a label.
local function layout(recs, rowOf)
  table.sort(recs, creationOrder)
  local byAddress = {}
  for _, rec in recs do
    byAddress[rec.address] = rec
  end
  local parentOf = {}
  local children = {}
  local roots = {}
  for _, rec in recs do
    local parent = nil
    if rec.parent ~= nil then
      parent = byAddress[rec.parent]
      if parent == nil and rec.machine ~= "" then
        parent = byAddress[`{rec.machine}/{rec.parent}`]
      end
    end
    local cycle = false
    local walk = parent
    while walk ~= nil do
      if walk == rec then
        cycle = true
        break
      end
      walk = parentOf[walk]
    end
    if parent == nil or cycle then
      table.insert(roots, rec)
    else
      parentOf[rec] = parent
      children[parent] = children[parent] or {}
      table.insert(children[parent], rec)
    end
  end
  local rows = {}
  local function emit(rec, depth)
    local row = rowOf[rec]
    row.depth = depth
    table.insert(rows, row)
    for _, child in children[rec] or {} do
      emit(child, depth + 1)
    end
  end
  for _, rec in roots do
    emit(rec, 0)
  end
  return rows
end

function Model:view()
  if self.cache ~= nil then
    return self.cache
  end
  local rowOf = {}
  local index = {}
  local attention = {}
  local history = {}
  local byMachine = {}
  local urgent, done, working = false, false, false
  for _, rec in self.terms do
    local stale = not self:reachable(rec)
    local lost = recovering(rec)
    local unseen = rec.status == "done" and rec.ep.seen < rec.ep.episode
    local row = {
      key = rec.key,
      address = rec.address,
      machine = rec.machine,
      parent = rec.parent,
      label = rec.name or rec.title or rec.address,
      state = rec.state,
      status = rec.status,
      statusAt = rec.statusAt,
      finishedAt = rec.finishedAt,
      exitCode = rec.exitCode,
      signal = rec.signal,
      reason = rec.reason,
      stale = stale,
      recovering = lost,
      unseenDone = unseen,
      depth = 0,
    }
    rowOf[rec] = row
    index[rec.key] = row
    if rec.state == "finished" then
      table.insert(history, row)
    else
      byMachine[rec.machine] = byMachine[rec.machine] or {}
      table.insert(byMachine[rec.machine], rec)
      if not stale and not lost then
        if URGENT_STATUS[rec.status] then
          urgent = true
          table.insert(attention, row)
        elseif unseen then
          done = true
          table.insert(attention, row)
        elseif rec.status == "working" then
          working = true
        end
      end
    end
  end

  table.sort(attention, function(a, b)
    local ra, rb = attentionRank(a), attentionRank(b)
    if ra ~= rb then
      return ra < rb
    end
    return newestFirst(a, b)
  end)
  table.sort(history, function(a, b)
    local at = a.finishedAt or -1
    local bt = b.finishedAt or -1
    if at ~= bt then
      return at > bt
    end
    return a.key < b.key
  end)

  local names = {}
  for name in byMachine do
    if name ~= "" then
      table.insert(names, name)
    end
  end
  for name in self.known do
    if byMachine[name] == nil then
      table.insert(names, name)
    end
  end
  table.sort(names)
  table.insert(names, 1, "")
  local groups = {}
  for _, name in names do
    local stale = self.feed ~= "live" or (name ~= "" and self.states[name] ~= "connected")
    table.insert(groups, { machine = name, stale = stale, rows = layout(byMachine[name] or {}, rowOf) })
  end

  local tone = "neutral"
  if self.feed == "stale" then
    tone = "offline"
  elseif urgent then
    tone = "urgent"
  elseif done then
    tone = "done"
  elseif working then
    tone = "working"
  end

  self.index = index
  self.cache = {
    feed = self.feed,
    attention = attention,
    groups = groups,
    history = history,
    tone = tone,
  }
  return self.cache
end

return Model
