--!nonstrict
local M = {
  STATUS_KEY = "herdr-core.status",
  CMD_KEY = "herdr-core.cmd",
  RESULT_KEY = "herdr-core.result",
  PANEL_ID = "tuanbinhtran/herdr-core:panel",
}
local host = nil
local nextId = 0

function M.bind(value)
  host = value
end

function M.quote(value)
  return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

function M.send(action, request)
  nextId += 1
  local message = table.clone(request or {})
  message.action = action
  message.id = `{if host then host.nowMs() else 0}-{nextId}`
  if host then host.state.set(M.CMD_KEY, message) end
  return message.id
end

return M
