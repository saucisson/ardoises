local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local assert    = require "luassert"
local Copas     = require "copas"
local Et        = require "etlua"
local Json      = require "cjson"
local Patterns  = require "ardoises.patterns"
local Websocket = require "websocket"

describe ("#editor", function ()

  it ("can be required", function ()
    assert.has.no.errors (function ()
      require "ardoises.editor"
    end)
  end)

  it ("can be instantiated", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "saucisson/lua-c3:master",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
    }
    assert.is_not_nil (editor)
  end)

  it ("can be started and explicitly stopped", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "saucisson/lua-c3:master",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    Copas.addthread (function ()
      editor:start ()
      editor:stop  ()
    end)
    Copas.loop ()
  end)

  it ("can receive connections", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ardoises/formalisms:master",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local connected
    Copas.addthread (function ()
      editor:start ()
      Copas.sleep (1)
      local url = Et.render ("ws://<%- host %>:<%- port %>", {
        host = editor.host,
        port = editor.port,
      })
      local client = Websocket.client.copas { timeout = 5 }
      connected    = client:connect (url, "ardoise")
      editor:stop ()
    end)
    Copas.loop ()
    assert.is_truthy (connected)
  end)

  it ("can authenticate", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ardoises/formalisms:master",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local answer
    Copas.addthread (function ()
      editor:start ()
      Copas.sleep (1)
      local url = Et.render ("ws://<%- host %>:<%- port %>", {
        host = editor.host,
        port = editor.port,
      })
      local client = Websocket.client.copas { timeout = 5 }
      client:connect (url, "ardoise")
      client:send (Json.encode {
        id    = 1,
        type  = "authenticate",
        token = assert (os.getenv "ARDOISES_TOKEN"),
      })
      answer = client:receive ()
      answer = Json.decode (answer)
      editor:stop ()
    end)
    Copas.loop ()
    assert.are.same (answer, {
      id      = 1,
      type    = "answer",
      success = true,
      answer  = {
        read  = true,
        write = true,
      }
    })
  end)

  it ("cannot start with wrong token", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ahamez/foo:master",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local started
    Copas.addthread (function ()
      started = editor:start ()
    end)
    Copas.loop ()
    assert.is_falsy (started)
  end)

  it ("can require after authenticate", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ardoises/formalisms:master",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local answers = {}
    Copas.addthread (function ()
      editor:start ()
      Copas.sleep (1)
      local url = Et.render ("ws://<%- host %>:<%- port %>", {
        host = editor.host,
        port = editor.port,
      })
      local client = Websocket.client.copas { timeout = 5 }
      client:connect (url, "ardoise")
      client:send (Json.encode {
        id    = 1,
        type  = "authenticate",
        token = assert (os.getenv "ARDOISES_TOKEN"),
      })
      answers.authenticate = client:receive ()
      answers.authenticate = Json.decode (answers.authenticate)
      client:send (Json.encode {
        id     = 2,
        type   = "require",
        module = "graph@ardoises/formalisms:dev",
      })
      answers.require = client:receive ()
      answers.require = Json.decode (answers.require)
      editor:stop ()
    end)
    Copas.loop ()
    answers.require.answer = nil
    assert.are.same (answers.require, {
      id      = 2,
      type    = "answer",
      success = true,
    })
  end)

  it ("can list after authenticate", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ardoises/formalisms:dev",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local answers = {}
    Copas.addthread (function ()
      editor:start ()
      Copas.sleep (1)
      local url = Et.render ("ws://<%- host %>:<%- port %>", {
        host = editor.host,
        port = editor.port,
      })
      local client = Websocket.client.copas { timeout = 5 }
      client:connect (url, "ardoise")
      client:send (Json.encode {
        id    = 1,
        type  = "authenticate",
        token = assert (os.getenv "ARDOISES_TOKEN"),
      })
      answers.authenticate = client:receive ()
      answers.authenticate = Json.decode (answers.authenticate)
      client:send (Json.encode {
        id   = 2,
        type = "list",
      })
      answers.list = client:receive ()
      answers.list = Json.decode (answers.list)
      editor:stop ()
    end)
    Copas.loop ()
    answers.list.answer = nil
    assert.are.same (answers.list, {
      id      = 2,
      type    = "answer",
      success = true,
    })
  end)

  it ("can create after authenticate", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ardoises/formalisms:dev",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local answers = {}
    Copas.addthread (function ()
      editor:start ()
      Copas.sleep (1)
      local url = Et.render ("ws://<%- host %>:<%- port %>", {
        host = editor.host,
        port = editor.port,
      })
      local client = Websocket.client.copas { timeout = 5 }
      client:connect (url, "ardoise")
      client:send (Json.encode {
        id    = 1,
        type  = "authenticate",
        token = assert (os.getenv "ARDOISES_TOKEN"),
      })
      answers.authenticate = client:receive ()
      answers.authenticate = Json.decode (answers.authenticate)
      client:send (Json.encode {
        id     = 2,
        type   = "create",
        module = "machin.truc.bidule@ardoises/formalisms:dev",
      })
      answers.create = client:receive ()
      answers.create = Json.decode (answers.create)
      editor:stop ()
    end)
    Copas.loop ()
    assert.are.same (answers.create, {
      id      = 2,
      type    = "answer",
      success = true,
      answer  = true,
    })
  end)

  it ("can delete after authenticate", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ardoises/formalisms:dev",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local answers = {}
    Copas.addthread (function ()
      editor:start ()
      Copas.sleep (1)
      local url = Et.render ("ws://<%- host %>:<%- port %>", {
        host = editor.host,
        port = editor.port,
      })
      local client = Websocket.client.copas { timeout = 5 }
      client:connect (url, "ardoise")
      client:send (Json.encode {
        id    = 1,
        type  = "authenticate",
        token = assert (os.getenv "ARDOISES_TOKEN"),
      })
      answers.authenticate = client:receive ()
      answers.authenticate = Json.decode (answers.authenticate)
      client:send (Json.encode {
        id     = 2,
        type   = "create",
        module = "machin.truc.bidule@ardoises/formalisms:dev",
      })
      answers.create = client:receive ()
      answers.create = Json.decode (answers.create)
      client:send (Json.encode {
        id     = 3,
        type   = "delete",
        module = "machin.truc.bidule@ardoises/formalisms:dev",
      })
      answers.delete = client:receive ()
      answers.delete = Json.decode (answers.delete)
      editor:stop ()
    end)
    Copas.loop ()
    assert.are.same (answers.delete, {
      id      = 3,
      type    = "answer",
      success = true,
      answer  = true,
    })
  end)

  it ("can patch after authenticate", function ()
    local Editor = require "ardoises.editor"
    local editor = Editor {
      branch      = Patterns.branch:match "ardoises/formalisms:dev",
      token       = os.getenv "ARDOISES_TOKEN",
      port        = 0,
      timeout     = 1,
      application = "Ardoises",
      nopush      = true,
    }
    local answers = {}
    Copas.addthread (function ()
      editor:start ()
      Copas.sleep (1)
      local url = Et.render ("ws://<%- host %>:<%- port %>", {
        host = editor.host,
        port = editor.port,
      })
      local client = Websocket.client.copas { timeout = 5 }
      client:connect (url, "ardoise")
      client:send (Json.encode {
        id    = 1,
        type  = "authenticate",
        token = assert (os.getenv "ARDOISES_TOKEN"),
      })
      answers.authenticate = client:receive ()
      answers.authenticate = Json.decode (answers.authenticate)
      client:send (Json.encode {
        id      = 2,
        type    = "patch",
        patches = {
          { module = "graph@ardoises/formalisms:dev",
            code   = [[ return function () end ]],
          },
          { module = "petrinet@ardoises/formalisms:dev",
            code   = [[ return function () end ]],
          },
        },
      })
      answers.patch = client:receive ()
      answers.patch = Json.decode (answers.patch)
      editor:stop ()
    end)
    Copas.loop ()
    assert.are.same (answers.patch, {
      id      = 2,
      type    = "answer",
      success = true,
      answer  = true,
    })
  end)

end)
