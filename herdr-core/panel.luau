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
local launchNotice = nil
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
local function rowStatus(row)
  local status = row.status or tr("status.unreported")
  if row.state == "finished" then status = tr("status.finished")
  elseif row.recovering then status = tr("status.recovering")
  elseif status == "blocked" or status == "error" or status == "done" or status == "working" or status == "idle" then
    status = tr("status." .. status)
  end
  return status
end
local function requestPreview(row)
  clearPreview()
  selectedKey = row.key
  if not row.stale and not row.recovering then
    previewRequest = send("preview", { key = row.key })
  end
  render()
end
local function rowActions(row)
  local enabled = not row.stale and not row.recovering
  local children = {}
  if row.unseenDone then
    table.insert(children, ui.button({ glyph = "check", tooltip = tr("panel.mark_seen"), controlSize = "sm", enabled = enabled, onClick = function() send("mark-seen", { key = row.key }) end }))
  end
  table.insert(children, ui.button({ glyph = "eye", tooltip = tr("panel.preview"), controlSize = "sm", enabled = enabled,
    onClick = function() requestPreview(row) end }))
  if row.state == "live" then
    table.insert(children, ui.button({ text = tr("panel.open"), variant = "primary", controlSize = "sm",
      enabled = enabled and pendingOpen == nil and pendingAttach == nil,
      onClick = function()
        if pendingOpen == nil and pendingAttach == nil then
          pendingAttach = nil
          pendingOpen = send("open", { key = row.key })
          render()
        end
      end }))
    table.insert(children, ui.button({ glyph = "terminal", tooltip = tr("panel.attach"), controlSize = "sm",
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
local function rowSubtitle(row)
  local subtitle = row.address
  if row.parent then subtitle ..= ` · {tr("panel.parent", { parent = row.parent })}` end
  if row.exitCode ~= nil then subtitle ..= ` · {tr("panel.exit_code", { code = row.exitCode })}` end
  if row.signal ~= nil then subtitle ..= ` · {tr("panel.signal", { signal = row.signal })}` end
  if row.stale then subtitle ..= ` · {tr("status.stale")}` end
  return subtitle
end
local function previewPane(row)
  if not row or (not previewRequest and previewText == nil) then return nil end
  local lines = {}
  if previewText == nil or previewText == "" then
    lines = { ui.label({ text = tr(if previewText == "" then "panel.no_output" else "panel.reading"),
      color = "on_surface_variant", fontSize = 12 }) }
  else
    -- One label per row keeps the terminal's columns. A row wider than the preview is cut off, not wrapped.
    for line in string.gmatch(previewText .. "\n", "([^\n]*)\n") do
      table.insert(lines, ui.label({ text = if line == "" then " " else line, fontFamily = "monospace", fontSize = 12, maxLines = 1 }))
    end
  end
  return ui.column({ gap = 4, flexGrow = 1 }, {
    ui.row({ align = "center", gap = 4 }, {
      ui.label({ text = tr(if previewIncomplete then "panel.preview_incomplete" else "panel.preview_title"),
        fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.button({ glyph = "x", tooltip = tr("panel.close_preview"), variant = "ghost", controlSize = "sm",
        onClick = function()
          clearPreview()
          render()
        end }),
    }),
    ui.scroll({ key = "output:" .. row.key, flexGrow = 1, padding = 8, radius = 8, fill = "on_surface/0.05", stickToBottom = true }, lines),
  })
end
local function statusBadge(row)
  local color = if row.stale or row.recovering then "on_surface_variant"
    elseif row.status == "blocked" or row.status == "error" then "error"
    elseif row.status == "done" then "tertiary" else "primary"
  return ui.row({ align = "center", paddingH = 7, paddingV = 3, radius = 8, fill = color .. "/0.12" }, {
    ui.label({ text = rowStatus(row), fontSize = 12, color = color, maxLines = 1 }),
  })
end
local function renderCard(row)
  local indent = if tab == "all" then math.min(row.depth or 0, 6) else 0
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = string.rep("  ", indent) .. row.label, maxLines = 1, flexGrow = 1, fontWeight = "bold" }),
      statusBadge(row),
    }),
    ui.label({ text = rowSubtitle(row), fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
  }
  if row.reason and row.reason ~= "" then
    table.insert(children, ui.label({ text = row.reason, fontSize = 12, color = "on_surface_variant", maxLines = 2 }))
  end
  table.insert(children, rowActions(row))
  return ui.column({ key = row.key, gap = 6, padding = 10, radius = 10,
    fill = if row.key == selectedKey then "primary/0.12" else "on_surface/0.05" }, children)
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
        launchNotice = nil
        pendingLaunch = send("launch", { template = chosen.name, cwd = cwd, task = taskText })
        render()
      end
    end,
  }))
  if launchNotice then
    if launchNotice.error then
      table.insert(children, ui.label({ text = launchNotice.error, color = "error", maxLines = 3 }))
    elseif launchNotice.warning then
      table.insert(children, ui.label({ text = launchNotice.warning, color = "tertiary", maxLines = 3 }))
    elseif launchNotice.address then
      table.insert(children, ui.label({ text = tr("panel.launched", { address = launchNotice.address }), color = "primary" }))
    end
  end
end
render = function()
  if not open then return end
  local view = snapshot.view or {}
  local liveCount = 0
  for _, group in view.groups or {} do liveCount += #group.rows end
  local function tabButton(name, count)
    return ui.button({ text = `{tr("panel." .. name)}  {count}`, selected = tab == name, controlSize = "sm",
      onClick = function() selectTab(name) end })
  end
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = tr("panel.title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "plus", text = tr("panel.new_run"), selected = tab == "new", controlSize = "sm",
        onClick = function() selectTab("new") end }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = tr("panel.close"), onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 6 }, {
      tabButton("attention", #(view.attention or {})),
      tabButton("all", liveCount),
      tabButton("history", #(view.history or {})),
    }),
  }
  if tab == "new" then
    renderNewRun(children)
  else
    local rows = if tab == "attention" then view.attention or {} elseif tab == "history" then view.history or {} else {}
    if tab == "all" then
      for _, group in view.groups or {} do
        local label = group.machine == "" and tr("panel.local") or group.machine
        if group.stale then label ..= ` · {tr("status.stale")}` end
        table.insert(rows, { key = `group:{group.machine}`, label = label,
          state = "group", stale = group.stale })
        for _, row in group.rows do table.insert(rows, row) end
      end
    end
    local selected
    if selectedKey then
      for _, row in rows do
        if row.key == selectedKey and row.state ~= "group" then selected = row; break end
      end
      if not selected then clearPreview() end
    end
    local empty = if view.feed == "stale" then snapshot.feedError or tr("status.feed_unavailable")
      elseif view.feed == "loading" then tr("panel.loading")
      else tr("panel.empty_" .. tab)
    if view.feed == "stale" and #rows > 0 then
      table.insert(children, ui.label({ text = empty, color = "error" }))
    end
    -- An open preview replaces the list, so it gets the panel's height. The selected card stays on top for its actions.
    local preview = previewPane(selected)
    if preview then
      table.insert(children, renderCard(selected))
      table.insert(children, preview)
    else
      local cards = {}
      for _, row in rows do
        table.insert(cards, if row.state == "group"
          then ui.label({ key = row.key, text = row.label, fontSize = 12, fontWeight = "bold", color = "primary", maxLines = 1 })
          else renderCard(row))
      end
      if #cards == 0 then
        table.insert(cards, ui.label({ text = empty, color = "on_surface_variant", maxLines = 2 }))
      end
      table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, cards))
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
  if value.id == pendingLaunch then
    pendingLaunch = nil
    launchNotice = value
    if noticeId == value.id then noticeId = nil; notice = nil end
  end
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
