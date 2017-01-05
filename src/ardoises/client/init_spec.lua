local Copas    = require "copas"
local Client   = require "ardoises.client"
local Gettime  = require "socket".gettime
local Instance = require "ardoises.server.instance"
local Mime     = require "mime"

describe ("#client", function ()

  local instance

  setup (function ()
    instance = Instance.create ()
  end)

  teardown (function ()
    instance:delete ()
  end)

  it ("can be instantiated", function ()
    local client
    Copas.addthread (function ()
      client = Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      }
    end)
    Copas.loop ()
    assert.is_not_nil (client)
  end)

  it ("can list and search existing ardoises", function ()
    local ardoises = {}
    Copas.addthread (function ()
      local client = Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      }
      for ardoise in client:ardoises () do
        ardoises [#ardoises+1] = ardoise
      end
    end)
    Copas.loop ()
    assert.is_truthy (#ardoises > 0)
  end)

  it ("can create and delete an ardoise", function ()
    local created, deleted
    Copas.addthread (function ()
      local client = Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      }
      local name = Mime.b64 (Gettime ())
      created = client:create ("ardoises-test/" .. name .. ":test")
      deleted = created:delete ()
    end)
    Copas.loop ()
    assert.is_truthy (created)
    assert.is_truthy (deleted)
  end)

  it ("can edit an ardoise", function ()
    local edited
    Copas.addthread (function ()
      local client = Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      }
      local name    = Mime.b64 (Gettime ())
      local ardoise = client:create ("ardoises-test/" .. name .. ":test")
      local editor  = ardoise:edit ()
      edited = not not editor
      editor:close ()
      ardoise:delete ()
    end)
    Copas.loop ()
    assert.is_truthy (edited)
  end)

end)
