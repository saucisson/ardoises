local assert   = require "luassert"
local Instance = require "ardoises.server.instance"

describe ("#instance", function ()

  it ("works", function ()
    local instance = Instance.create ()
    local server = instance.server
    instance:delete ()
    assert.is_truthy (server)
  end)

end)
