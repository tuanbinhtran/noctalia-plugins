--!nonstrict
local M = {}

function M.new(host, resolve, complete, quote)
  local actions = {}
  local busy = {}
  local previewRequest = nil
  local opened = {}
  local launchBusy = false
  local function finish(id, kind, key, fields)
    local value = { id = id, kind = kind, key = key, pending = false }
    for name, field in fields or {} do value[name] = field end
    complete(value)
  end
  local function errorText(key)
    return host.tr(key)
  end
  local function run(argv, callback, timeout)
    local ok = host.runAsync(argv, callback, timeout)
    return ok ~= false
  end
  local function decode(result)
    if not result or result.exitCode ~= 0 then return nil end
    local ok, value = pcall(host.json.decode, result.stdout or "")
    if ok then return value end
    return nil
  end
  local function commandError(result, body)
    local detail = errorText("action.failed")
    if type(body) == "table" and type(body.error) == "string" then
      detail = body.error
    elseif result and type(result.stderr) == "string" and result.stderr ~= "" then
      local stderr = result.stderr
      local ok, envelope = pcall(host.json.decode, stderr)
      if ok and type(envelope) == "table" then
        if type(envelope.error) == "string" then
          detail = envelope.error
        elseif type(envelope.error) == "table" and type(envelope.error.message) == "string" then
          detail = envelope.error.message
        else
          detail = stderr
        end
      else
        detail = stderr
      end
    end
    return host.tr("action.command_failed", { error = detail })
  end
  local function accepted(value)
    return type(value) == "table" and value.ok == true and value.error == nil
  end
  local function validTemplate(template)
    return type(template) == "table"
      and type(template.name) == "string" and string.match(template.name, "%S") ~= nil
      and template.error == nil
      and type(template.command) == "string" and string.match(template.command, "%S") ~= nil
  end
  local function attach(id, row)
    local ok = host.runInTerminal("hc attach " .. quote(row.address))
    if ok then
      finish(id, "attached", row.key)
    else
      finish(id, "attach", row.key, { error = errorText("action.attach_failed") })
    end
  end
  local function current(key)
    local row = resolve(key)
    if not row or row.key ~= key then return nil end
    if row.stale or row.recovering then return nil end
    return row
  end
  local function isUnavailable(result)
    if not result then return false end
    local err = string.lower(result.stderr or "")
    local hasWindowError = string.find(err, "no herdr window", 1, true) ~= nil
    local hasSocketErrno = string.find(err, "enoent", 1, true) ~= nil
      or string.find(err, "econnrefused", 1, true) ~= nil
      or string.find(err, "os error 2", 1, true) ~= nil
      or string.find(err, "connection refused", 1, true) ~= nil
    return hasWindowError and hasSocketErrno
  end
  local function isPlaced(address, layout)
    if type(layout) ~= "table" or type(layout.spaces) ~= "table" then return nil end
    for _, space in layout.spaces do
      if type(space) ~= "table" or type(space.tabs) ~= "table" then return nil end
      for _, tab in space.tabs do
        if type(tab) ~= "table" or type(tab.terminals) ~= "table" then return nil end
        for _, terminal in tab.terminals do
          if type(terminal) == "table" and terminal.terminal == address then return true end
        end
      end
    end
    return false
  end
  local function open(id, key)
    local row = current(key)
    if not row or row.state ~= "live" then finish(id, "open", key, { error = errorText("action.unavailable") }); return end
    if busy[key] then finish(id, "open", key, { error = errorText("action.busy") }); return end
    if host.getConfig("open_in_terminal_only") == true or host.getenv("HC_SESSION") ~= nil or host.getenv("HC_SOCKET") ~= nil then
      attach(id, row); return
    end
    if not host.commandExists("herdr-app") then attach(id, row); return end
    busy[key] = id
    local address = row.address
    local function release()
      if busy[key] == id then busy[key] = nil end
    end
    local function failOpen(message)
      release()
      finish(id, "open", key, { error = message })
    end
    local function selectedRun()
      local selected = current(key)
      if selected and selected.state == "live" and selected.address == address then
        return selected
      end
      failOpen(errorText("action.unavailable"))
      return nil
    end
    local function attachIfAppAbsent(result, selected)
      if not isUnavailable(result) then return false end
      release()
      attach(id, selected)
      return true
    end
    local function onAppAction(result)
      local selected = selectedRun()
      if not selected then return end
      local body = decode(result)
      if accepted(body) then
        release()
        opened[id] = true
        finish(id, "open-app", key)
      elseif not attachIfAppAbsent(result, selected) then
        failOpen(commandError(result, body))
      end
    end
    local function onLayout(result)
      local selected = selectedRun()
      if not selected then return end
      local layout = decode(result)
      if not layout then
        if not attachIfAppAbsent(result, selected) then
          failOpen(host.tr("action.command_failed", { error = (result and result.stderr) or "" }))
        end
        return
      end
      local placed = isPlaced(address, layout)
      if placed == nil then
        failOpen(errorText("action.malformed_layout"))
        return
      end
      local operation = if placed then "pane.focus" else "terminal.peek"
      if not run({ "herdr-app", "do", operation, "--terminal", address }, onAppAction) then
        failOpen(host.tr("action.command_failed", { error = "" }))
      end
    end
    if not run({ "herdr-app", "ls" }, onLayout) then
      failOpen(errorText("action.failed"))
    end
  end
  local function stripOsc(value)
    local chunks = {}
    local first = 1
    local index = 1
    local length = #value
    local found = false
    while index < length do
      if string.byte(value, index) == 27 and string.byte(value, index + 1) == 93 then
        found = true
        table.insert(chunks, string.sub(value, first, index - 1))
        index += 2
        while index <= length do
          local byte = string.byte(value, index)
          if byte == 7 then
            index += 1
            break
          elseif byte == 27 and string.byte(value, index + 1) == 92 then
            index += 2
            break
          end
          index += 1
        end
        first = index
      else
        index += 1
      end
    end
    if not found then return value end
    table.insert(chunks, string.sub(value, first))
    return table.concat(chunks)
  end
  local function publishPreview(id, key)
    local row = current(key)
    if not row then finish(id, "preview", key, { error = errorText("action.unavailable") }); return end
    previewRequest = id
    local address = row.address
    if not run({ "hc", "read", "--json", "--lines", "40", address }, function(result)
      if previewRequest ~= id then return end
      local selected = current(key)
      if not selected or selected.address ~= address then
        finish(id, "preview", key, { error = errorText("action.unavailable") })
        return
      end
      local body = decode(result)
      if type(body) ~= "table" or type(body.text) ~= "string" then
        finish(id, "preview", key, { error = commandError(result, body) })
        return
      end
      local text = string.gsub(body.text, "\27%[[0-?]*[ -/]*[@-~]", "")
      text = stripOsc(text)
      text = string.gsub(text, "\27[P^_X][^\27]*\27\\", "")
      text = string.gsub(text, "\27[ -/]*[@-~]", "")
      text = string.gsub(text, "[%z\1-\8\11\12\14-\31\127]", "")
      text = string.gsub(text, "\r", "")
      local truncated = #text > 16384
      if truncated then
        text = string.sub(text, #text - 16383)
        while #text > 0 and string.byte(text, 1) >= 128 and string.byte(text, 1) < 192 do
          text = string.sub(text, 2)
        end
      end
      local stdoutTruncated = result and (result.stdoutTruncated == true or result.truncated == true) or false
      finish(id, "preview", key, {
        preview = text, incomplete = body.complete ~= true, truncated = truncated or stdoutTruncated,
      })
    end) then finish(id, "preview", key, { error = errorText("action.failed") }) end
  end
  local function templates(id)
    if not run({ "hc", "templates", "--json" }, function(result)
      local body = decode(result)
      if type(body) ~= "table" or type(body.templates) ~= "table" then
        finish(id, "templates", nil, { error = commandError(result, body) })
        return
      end
      local valid = {}
      for _, template in body.templates do
        if validTemplate(template) then
          local entry = { name = template.name }
          if type(template.description) == "string" then entry.description = template.description end
          table.insert(valid, entry)
        end
      end
      finish(id, "templates", nil, { templates = valid })
    end) then finish(id, "templates", nil, { error = errorText("action.failed") }) end
  end
  local function launch(id, request)
    if launchBusy then finish(id, "launch", nil, { error = errorText("action.busy") }); return end
    local name, task, cwd = request.template, request.task, request.cwd
    if type(name) ~= "string" or string.match(name, "%S") == nil
      or type(task) ~= "string" or string.match(task, "%S") == nil or #task > 4096
    then
      finish(id, "launch", nil, { error = errorText("action.invalid_launch") })
      return
    end
    if type(cwd) ~= "string" or cwd == "" then cwd = "~" end
    cwd = host.expandPath(cwd)
    if type(cwd) ~= "string" then finish(id, "launch", nil, { error = errorText("action.invalid_cwd") }); return end
    local info = host.fileInfo(cwd)
    if string.sub(cwd, 1, 1) ~= "/" or type(info) ~= "table" or info.isDir ~= true then
      finish(id, "launch", nil, { error = errorText("action.invalid_cwd") })
      return
    end
    launchBusy = true
    local function completeLaunch(fields)
      launchBusy = false
      finish(id, "launch", nil, fields)
    end
    if not run({ "hc", "templates", "--json" }, function(result)
      local body = decode(result)
      if type(body) ~= "table" or type(body.templates) ~= "table" then
        completeLaunch({ error = commandError(result, body) })
        return
      end
      local found = false
      for _, item in body.templates do
        if validTemplate(item) and item.name == name then found = true; break end
      end
      if not found then completeLaunch({ error = errorText("action.template_missing") }); return end
      if not run({ "hc", "run", "--json", "--bg", "--no-parent", "--cwd", cwd, "--", name, " " .. task }, function(launched)
        if launched and launched.timedOut == true then
          completeLaunch({ warning = host.tr("action.launch_pending") })
          return
        end
        local payload = decode(launched)
        if type(payload) ~= "table" or payload.error ~= nil then
          completeLaunch({ error = commandError(launched, payload) })
          return
        end
        if type(payload.address) ~= "string" or string.match(payload.address, "%S") == nil then
          completeLaunch({ error = errorText("action.failed") })
          return
        end
        local fields = { address = payload.address }
        if payload.first_message and payload.first_message.sent == false then
          fields.warning = host.tr("action.message_not_sent", { reason = payload.first_message.reason or "" })
        end
        completeLaunch(fields)
      end, 60000) then
        completeLaunch({ error = errorText("action.failed") })
      end
    end) then
      completeLaunch({ error = errorText("action.failed") })
    end
  end
  function actions:dispatch(request)
    if type(request) ~= "table" or type(request.id) ~= "string" then return end
    local id, kind, key = request.id, request.action, request.key
    if kind == "open" then open(id, key)
    elseif kind == "attach" then
      local row = current(key)
      if row and row.state == "live" then attach(id, row)
      else finish(id, kind, key, { error = errorText("action.unavailable") }) end
    elseif kind == "raise-app" then
      local openedId = request.openedId
      if opened[openedId] then
        opened[openedId] = nil
        local niri = host.getenv("NIRI_SOCKET")
        if niri ~= nil and niri ~= "" and host.commandExists("niri") then
          local started = run({ "niri", "msg", "--json", "windows" }, function(result)
            local windows = decode(result)
            local matches = {}
            if type(windows) == "table" then
              for _, window in windows do
                if type(window) == "table" and window.app_id == "herdr-app" and type(window.id) == "number" then
                  table.insert(matches, window)
                end
              end
            end
            if #matches == 1 then
              local focused = run({ "niri", "msg", "action", "focus-window", "--id", tostring(matches[1].id) }, function(response)
                if not response or response.exitCode ~= 0 then run({ "herdr-app" }, function() end) end
              end)
              if not focused then run({ "herdr-app" }, function() end) end
            else
              run({ "herdr-app" }, function() end)
            end
          end)
          if not started then run({ "herdr-app" }, function() end) end
        else
          run({ "herdr-app" }, function() end)
        end
      end
    elseif kind == "preview" then publishPreview(id, key)
    elseif kind == "cancel-preview" then previewRequest = nil
    elseif kind == "templates" then templates(id)
    elseif kind == "launch" then launch(id, request) end
  end
  return actions
end

return M
