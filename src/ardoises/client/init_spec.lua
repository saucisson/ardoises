local Copas   = require "copas"
local Client  = require "ardoises.client"
local Gettime = require "socket".gettime
local Mime    = require "mime"

describe ("#client", function ()

  it ("can be instantiated", function ()
    local client
    Copas.addthread (function ()
      client = Client {
        server = "http://localhost:8080",
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

  it ("can create and delete an ardoise", function ()
    local created, deleted
    Copas.addthread (function ()
      local client = Client {
        server = "http://localhost:8080",
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

end)
