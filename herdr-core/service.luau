--!nonstrict
local Model = require("./lib/model.luau")
local Protocol = require("./lib/protocol.luau")
local Controller = require("./lib/controller.luau")
local Actions = require("./lib/actions.luau")
Protocol.bind(noctalia)
local controller = Controller.new(noctalia, Model.new(), Protocol, Actions)

function update()
  controller:update()
end

function onConfigChanged()
  controller:onConfigChanged()
end

controller:start()
