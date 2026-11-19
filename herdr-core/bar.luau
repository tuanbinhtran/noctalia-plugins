--!nonstrict
local Protocol = require("./lib/protocol.luau")
local tr = noctalia.tr
local trp = noctalia.trp
local status = { view = { feed = "loading", attention = {}, tone = "neutral" } }

local colors = { offline = "error", urgent = "error", done = "primary", working = "tertiary", neutral = "on_surface" }
local glyphs = { offline = "wifi-off", urgent = "alert-triangle", done = "circle-check", working = "loader", neutral = "terminal" }
local function render()
  local view = status.view or {}
  local count = #(view.attention or {})
  local tone = view.tone or "neutral"
  barWidget.setGlyph(glyphs[tone] or glyphs.neutral)
  barWidget.setGlyphColor(colors[tone] or colors.neutral)
  barWidget.setColor("on_surface")
  barWidget.setText(count > 0 and tostring(count) or "")
  local description = view.feed == "stale" and tr("bar.offline") or trp("bar.attention", count)
  barWidget.setTooltip({ { tr("bar.summary"), description } })
end
noctalia.state.watch(Protocol.STATUS_KEY, function(value)
  if type(value) == "table" then status = value; render() end
end)
status = noctalia.state.get(Protocol.STATUS_KEY) or status

function onClick() noctalia.togglePanel(Protocol.PANEL_ID) end
