local Copas  = require "copas"
local Client = require "ardoises.client"

describe ("Ardoises client", function ()

  it ("can be instantiated", function ()
    local client
    Copas.addthread (function ()
      client = Client.new {
        server = "http://localhost:8080",
        token  = os.getenv "ARDOISES_TOKEN",
      }
    end)
    Copas.loop ()
    assert.is_not_nil (client)
  end)

  it ("can list and search existing ardoises", function ()
    local client
    local ardoises = {}
    Copas.addthread (function ()
      client = Client.new {
        server = "http://localhost:8080",
        token  = os.getenv "ARDOISES_TOKEN",
      }
      for ardoise in client:ardoises () do
        ardoises [#ardoises+1] = ardoise
      end
    end)
    Copas.loop ()
    assert.is_truthy (#ardoises > 0)
  end)

  it ("can create a new ardoise", function ()
    local client
    Copas.addthread (function ()
      client = Client.new {
        server = "http://localhost:8080",
        token  = os.getenv "ARDOISES_TOKEN",
      }
      client:create {
        name = "test-ardoise",
      }
    end)
    Copas.loop ()
  end)

end)
