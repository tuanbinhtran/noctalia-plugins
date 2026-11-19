--!nonstrict
local M = {}


function M.new(host, model, protocol, ActionModule)
  local startedAt = nil
  local lastAlive = nil
  local generation = 0
  local machineBusy = false
  local nextMachineAt = nil
  local watchdogStale = false
  local aliveAfterWatchdog = false
  local heartbeatSeqAfterWatchdog = nil
  local lastView = nil
  local controller = {}

  local function public()
    local view = model:view()
    local result = { view = view }
    if view.feed == "stale" then result.feedError = host.tr("status.feed_unavailable") end
    return result
  end

  local function publish()
    local value = public()
    if lastView == nil or value.view ~= lastView then
      host.state.set(protocol.STATUS_KEY, value)
      lastView = value.view
    end
  end
  local actions = if ActionModule then ActionModule.new(host, function(key) return model:resolve(key) end, function(result)
    host.state.set(protocol.RESULT_KEY, result)
  end, protocol.quote) else nil
  host.state.watch(protocol.CMD_KEY, function(request)
    if type(request) ~= "table" then return end
    if request.action == "mark-seen" then
      local changed = model:markSeen(request.key)
      host.state.set(protocol.RESULT_KEY, {
        id = request.id, kind = "mark-seen", key = request.key, pending = false,
        error = if changed then nil else host.tr("action.unavailable"),
      })
      if changed then publish() end
    elseif actions then
      actions:dispatch(request)
    else
      host.state.set(protocol.RESULT_KEY, {
        id = request.id, kind = request.action, key = request.key, pending = false,
        error = host.tr("action.unavailable"),
      })
    end
  end)


  local function queryMachines()
    local now = host.nowMs()
    if machineBusy or model.feed ~= "live" or (nextMachineAt ~= nil and now < nextMachineAt) then
      return
    end
    machineBusy = true
    nextMachineAt = now + 15000
    local token = generation
    local ok = host.runAsync({ "hc", "machine", "ls", "--json" }, function(result)
      machineBusy = false
      if token ~= generation then return end
      if result and result.exitCode == 0 then
        local decodedOk, decoded = pcall(host.json.decode, result.stdout)
        model:setMachines(decodedOk and type(decoded) == "table" and decoded.machines or nil)
      else
        model:setMachines(nil)
      end
      publish()
    end)
    if not ok then
      machineBusy = false
      model:setMachines(nil)
      publish()
    end
  end

  local function resumeIfConfirmed()
    if
      watchdogStale
      and aliveAfterWatchdog
      and heartbeatSeqAfterWatchdog ~= nil
      and heartbeatSeqAfterWatchdog == model.seq
      and model:resumeWatchdogFeed()
    then
      watchdogStale = false
      aliveAfterWatchdog = false
      heartbeatSeqAfterWatchdog = nil
      nextMachineAt = host.nowMs()
      queryMachines()
      publish()
    end
  end

  function controller:start()
    startedAt = host.nowMs()
    lastAlive = nil
    if not host.commandExists("hc") or not host.commandExists("python3") then
      model:setFeedDown()
      publish()
      return
    end
    local command = "exec python3 -u " .. protocol.quote(host.pluginDir() .. "/event_stream.py")
    local started = host.runStream(command, function(line) controller:onLine(line) end)
    if started == false then
      model:setFeedDown()
      publish()
      return
    end
    publish()
  end

  function controller:onLine(line)
    local ok, frame = pcall(host.json.decode, line)
    if not ok or type(frame) ~= "table" then return end
    local now = host.nowMs()
    if frame.plugin == "alive" then
      lastAlive = now
      if watchdogStale then
        aliveAfterWatchdog = true
        resumeIfConfirmed()
      end
      return
    elseif frame.plugin == "feed-down" then
      generation += 1
      watchdogStale = false
      aliveAfterWatchdog = false
      heartbeatSeqAfterWatchdog = nil
      nextMachineAt = nil
      model:setFeedDown()
      publish()
      return
    elseif frame.method == nil and type(frame.seq) == "number" and type(frame.terminals) == "table" then
      local wasExpectingSnapshot = model.expectSnapshot
      model:apply(frame, now)
      if wasExpectingSnapshot and not model.expectSnapshot then
        generation += 1
        watchdogStale = false
        aliveAfterWatchdog = false
        heartbeatSeqAfterWatchdog = nil
        nextMachineAt = now
        queryMachines()
      end
    elseif frame.method == "heartbeat" then
      local params = frame.params
      if
        watchdogStale
        and type(params) == "table"
        and type(params.seq) == "number"
        and params.seq == model.seq
      then
        heartbeatSeqAfterWatchdog = params.seq
        resumeIfConfirmed()
      end
    else
      local notices = model:apply(frame, now)
      if type(notices) == "table" and host.getConfig("notifications_enabled") == true then
        for _, notice in notices do
          host.notify(host.tr("notification.title"), host.tr("notification.body", {
            label = notice.label, status = host.tr("status." .. notice.status),
          }))
        end
      end
    end
    publish()
  end

  function controller:update()
    local now = host.nowMs()
    local reference = lastAlive or startedAt
    if not watchdogStale and reference ~= nil and now - reference >= 25000 and model.feed ~= "stale" then
      watchdogStale = true
      aliveAfterWatchdog = false
      heartbeatSeqAfterWatchdog = nil
      generation += 1
      model:setWatchdogStale()
      publish()
    end
    if model.feed == "live" and (nextMachineAt == nil or now >= nextMachineAt) then
      queryMachines()
    end
  end

  function controller:onConfigChanged()
    publish()
  end


  return controller
end

return M

