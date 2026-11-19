--!nonstrict
local Protocol = require("./lib/protocol.luau")
Protocol.bind(noctalia)
local tr = noctalia.tr
local snapshot = { view = { feed = "loading", attention = {}, groups = {}, history = {} } }
local open = false
local tab = "attention"
local selectedKey = nil
local templateRows = {}
local templateChoice = 0
local cwd = "~"
local taskText = ""
local formKey = 0
local noticeId = nil
local notice = nil
local templateRequest = nil
local previewRequest = nil
local pendingAttach = nil
local pendingRaise = nil
local pendingLaunch = nil
local previewText = nil
local previewIncomplete = false
local pendingOpen = nil
local render

local function send(action, fields)
  local id = Protocol.send(action, fields)
  if action ~= "cancel-preview" and action ~= "raise-app" then
    noticeId = id
    notice = nil
  end
  if action == "templates" then templateRequest = id end
  return id
end
local function clearPreview()
  if previewRequest then send("cancel-preview") end
  previewRequest = nil
  selectedKey = nil
  previewText = nil
  previewIncomplete = false
end
local function clearNotice()
  noticeId = nil
  notice = nil
end
local function selectTab(value)
  clearPreview()
  clearNotice()
  tab = value
  render()
end
local function rowTitle(row)
  local status = row.status or tr("status.unreported")
  if row.state == "finished" then status = tr("status.finished")
  elseif row.recovering then status = tr("status.recovering")
  elseif status == "blocked" or status == "error" or status == "done" or status == "working" or status == "idle" then
    status = tr("status." .. status)
  end
  return `{row.label} · {status}`
end
local function rowActions(row)
  local enabled = not row.stale and not row.recovering
  local children = {}
  if row.unseenDone then
    table.insert(children, ui.button({ text = tr("panel.mark_seen"), enabled = enabled, onClick = function() send("mark-seen", { key = row.key }) end }))
  end
  table.insert(children, ui.button({ text = tr("panel.preview"), enabled = enabled, onClick = function()
    if selectedKey ~= row.key then clearPreview() end
    selectedKey = row.key
    previewText = nil
    previewIncomplete = false
    previewRequest = send("preview", { key = row.key })
  end }))
  if row.state == "live" then
    table.insert(children, ui.button({ text = tr("panel.open"), variant = "primary",
      enabled = enabled and pendingOpen == nil and pendingAttach == nil,
      onClick = function()
        if pendingOpen == nil and pendingAttach == nil then
          pendingAttach = nil
          pendingOpen = send("open", { key = row.key })
          render()
        end
      end }))
    table.insert(children, ui.button({ text = tr("panel.attach"),
      enabled = enabled and pendingOpen == nil and pendingAttach == nil,
      onClick = function()
        if pendingOpen == nil and pendingAttach == nil then
          pendingOpen = nil
          pendingAttach = send("attach", { key = row.key })
          render()
        end
      end }))
  end
  return ui.row({ gap = 6, align = "center" }, children)
end
local function renderRow(row)
  if row.state == "group" then
    return ui.label({ key = row.key, text = row.label, fontWeight = "bold", color = "primary" })
  end
  local title = rowTitle(row)
  local subtitle = row.address
  if row.parent then subtitle ..= ` · {tr("panel.parent", { parent = row.parent })}` end
  if row.exitCode ~= nil then subtitle ..= ` · {tr("panel.exit_code", { code = row.exitCode })}` end
  if row.signal ~= nil then subtitle ..= ` · {tr("panel.signal", { signal = row.signal })}` end
  if row.stale then subtitle ..= ` · {tr("status.stale")}` end
  return ui.column({ key = row.key, gap = 6, padding = 10, radius = 10, fill = "on_surface/0.05", paddingH = 10 }, {
    ui.label({ text = string.rep("  ", math.min(row.depth or 0, 6)) .. title, fontWeight = "medium", maxLines = 1 }),
    ui.label({ text = subtitle, fontSize = 12, color = "on_surface_variant" }),
    row.reason and ui.label({ text = row.reason, fontSize = 12, color = "on_surface_variant" }) or ui.spacer({ height = 0 }),
    rowActions(row),
  })
end
local function renderNewRun(children)
  local options = {}
  for _, template in templateRows do table.insert(options, template.name) end
  table.insert(children, ui.label({ text = tr("panel.new_run"), fontWeight = "bold" }))
  table.insert(children, ui.button({ text = tr("panel.load_templates"), onClick = function() send("templates") end }))
  if #options > 0 then
    local choice = math.clamp(templateChoice, 1, #options)
    table.insert(children, ui.select({ key = "herdr-template-select", options = options, selectedIndex = choice - 1,
      onChange = function(value)
        local index = tonumber(value)
        if index then
          templateChoice = math.clamp(index + 1, 1, #options)
          render()
        end
      end,
    }))
    local chosen = templateRows[choice]
    if chosen and chosen.description then table.insert(children, ui.label({ text = chosen.description, color = "on_surface_variant" })) end
  end
  table.insert(children, ui.input({ key = `herdr-cwd-{formKey}`, value = cwd, placeholder = tr("panel.cwd"), onChange = function(value) cwd = value end }))
  table.insert(children, ui.input({ key = `herdr-task-{formKey}`, multiline = true, height = 120, value = taskText,
    placeholder = tr("panel.task"), onChange = function(value) taskText = value end }))
  table.insert(children, ui.button({ text = tr("panel.launch"), variant = "primary", enabled = #options > 0 and pendingLaunch == nil,
    onClick = function()
      local chosen = templateRows[math.clamp(templateChoice, 1, #templateRows)]
      if chosen and pendingLaunch == nil then
        pendingLaunch = send("launch", { template = chosen.name, cwd = cwd, task = taskText })
        render()
      end
    end,
  }))
end
render = function()
  if not open then return end
  local view = snapshot.view or {}
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = tr("panel.title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = view.feed == "stale" and tr("status.stale") or "", color = "error" }),
      ui.button({ glyph = "x", variant = "ghost", tooltip = tr("panel.close"), onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 6 }, {
      ui.button({ text = tr("panel.attention"), selected = tab == "attention", onClick = function() selectTab("attention") end }),
      ui.button({ text = tr("panel.all"), selected = tab == "all", onClick = function() selectTab("all") end }),
      ui.button({ text = tr("panel.history"), selected = tab == "history", onClick = function() selectTab("history") end }),
      ui.button({ text = tr("panel.new_run"), selected = tab == "new", onClick = function() selectTab("new") end }),
    }),
  }
  if tab == "new" then
    renderNewRun(children)
  else
    local rows = {}
    if tab == "attention" then
      for _, row in view.attention or {} do table.insert(rows, row) end
    elseif tab == "history" then
      for _, row in view.history or {} do table.insert(rows, row) end
    else
      for _, group in view.groups or {} do
        local label = group.machine == "" and tr("panel.local") or group.machine
        if group.stale then label ..= ` · {tr("status.stale")}` end
        table.insert(rows, { key = `group:{group.machine}`, label = label,
          state = "group", stale = group.stale })
        for _, row in group.rows do table.insert(rows, row) end
      end
    end
    local rendered = {}
    for _, row in rows do table.insert(rendered, renderRow(row)) end
    if view.feed == "stale" then
      table.insert(rendered, ui.label({ text = snapshot.feedError or tr("status.feed_unavailable"), color = "error" }))
    elseif #rendered == 0 then
      table.insert(rendered, ui.label({ text = tr("panel.empty"), color = "on_surface_variant" }))
    end
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, rendered))
    if selectedKey and previewText then
      table.insert(children, ui.label({ text = tr(previewIncomplete and "panel.preview_incomplete" or "panel.preview_title"), fontWeight = "bold" }))
      table.insert(children, ui.scroll({ height = 180, padding = 8, fill = "on_surface/0.05" }, { ui.label({ text = previewText, fontFamily = "monospace" }) }))
    end
  end
  if notice and notice.error then
    table.insert(children, ui.label({ text = notice.error, color = "error", maxLines = 3 }))
  elseif notice and notice.warning then
    table.insert(children, ui.label({ text = notice.warning, color = "tertiary", maxLines = 3 }))
  elseif notice and notice.address then
    table.insert(children, ui.label({ text = tr("panel.launched", { address = notice.address }), color = "primary" }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 12 }, children))
end

noctalia.state.watch(Protocol.STATUS_KEY, function(value)
  if type(value) == "table" then snapshot = value; render() end
end)
noctalia.state.watch(Protocol.RESULT_KEY, function(value)
  if type(value) ~= "table" then return end
  if value.kind == "templates" and value.id == templateRequest then
    templateRequest = nil
    if not value.error then
      templateRows = value.templates or {}
      templateChoice = math.min(math.max(1, templateChoice), math.max(1, #templateRows))
    end
  end
  if value.kind == "preview" and value.id == previewRequest and selectedKey == value.key then
    previewRequest = nil
    if not value.error then
      previewText = value.preview
      previewIncomplete = value.incomplete or value.truncated
    end
  end
  if value.id == pendingOpen and value.error then pendingOpen = nil end
  if value.id == pendingAttach and value.error then pendingAttach = nil end
  if value.id == pendingLaunch then pendingLaunch = nil end
  if value.kind == "attached" and not value.error and open
    and (value.id == pendingOpen or value.id == pendingAttach)
  then
    panel.close()
    return
  end
  if value.id == pendingOpen and value.kind == "open-app" and not value.error and open then
    pendingRaise = value.id
    panel.close()
    return
  end
  if value.id == noticeId then notice = value end
  render()
end)
snapshot = noctalia.state.get(Protocol.STATUS_KEY) or snapshot

function onOpen(_context)
  open = true
  tab = "attention"
  formKey += 1
  clearPreview()
  clearNotice()
  pendingOpen = nil
  pendingAttach = nil
  render()
  send("templates")
end
function onClose()
  open = false
  if pendingRaise then
    Protocol.send("raise-app", { openedId = pendingRaise })
    pendingRaise = nil
  end
  clearPreview()
  clearNotice()
  pendingOpen = nil
  pendingAttach = nil
end
