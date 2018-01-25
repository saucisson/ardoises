local Copas  = require "copas"
local Client = require "ardoises.client"

describe ("#client", function ()

  local instance = {
    server = "http://localhost:8080",
  }

  it ("can be instantiated", function ()
    local client
    Copas.addthread (function ()
      client = assert (Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      })
    end)
    Copas.loop ()
    assert.is_not_nil (client)
  end)

  it ("can list and search existing ardoises", function ()
    local ardoises = {}
    Copas.addthread (function ()
      local client = assert (Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      })
      for ardoise in client:ardoises () do
        ardoises [#ardoises+1] = ardoise
      end
    end)
    Copas.loop ()
    assert.is_truthy (#ardoises > 0)
  end)

  it ("can get an ardoise", function ()
    local ardoise
    Copas.addthread (function ()
      local client = assert (Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      })
      ardoise = client:ardoise "ardoises/test-ardoise"
    end)
    Copas.loop ()
    assert.is_truthy (ardoise)
  end)

  it ("can edit an ardoise", function ()
    local edited
    Copas.addthread (function ()
      local client = Client {
        server = instance.server,
        token  = os.getenv "ARDOISES_TOKEN",
      }
      local ardoise = client:ardoise "ardoises/test-ardoise"
      local editor  = ardoise:edit ()
      edited = not not editor
      editor:close ()
    end)
    Copas.loop ()
    assert.is_truthy (edited)
  end)

end)
