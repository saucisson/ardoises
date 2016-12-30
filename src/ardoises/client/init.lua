local Coromake  = require "coroutine.make"
_G.coroutine    = Coromake ()
local Copas     = require "copas"
local Et        = require "etlua"
local Json      = require "cjson"
local Mime      = require "mime"
local Url       = require "socket.url"
local Layer     = require "layeredata"
local Http      = require "ardoises.http".copas
local Patterns  = require "ardoises.patterns"
local Websocket = require "websocket"

local function assert (condition, t)
  if not condition then
    error (t)
  else
    return condition
  end
end

local Client  = {}
local Ardoise = {}
local Editor  = {}

Client .__index = Client
Ardoise.__index = Ardoise
Editor .__index = Editor

Client.accept     = "application/vnd.github.v3+json"
Client.user_agent = "Ardoises Client"

function Client.__init (options)
  assert (type (options) == "table", {
    error  = "options must be a table",
    reason = type (options),
  })
  assert (type (options.server) == "string"
      and Url.parse (options.server).scheme
      and Url.parse (options.server).host, {
    error  = "options must define a server url",
    reason = "invalid server",
  })
  assert (type (options.token) == "string", {
    error  = "options must define an authentication token",
    reason = "invalid token",
  })
  local server = Url.parse (options.server)
  local token  = options.token
  local user, status = Http {
    redirect = false,
    url      = "https://api.github.com/user",
    method   = "GET",
    headers  = {
      ["Accept"       ] = Client.accept,
      ["User-Agent"   ] = Client.user_agent,
      ["Authorization"] = "token " .. token,
    },
  }
  assert (status == 200, {
    error  = "cannot authenticate",
    reason = status,
  })
  do
    local emails, estatus = Http {
      url     = "https://api.github.com/user/emails",
      method  = "GET",
      headers = {
        ["Accept"       ] = Client.accept,
        ["User-Agent"   ] = Client.user_agent,
        ["Authorization"] = "token " .. token,
      },
    }
    assert (estatus == 200, {
      error  = "cannot obtain email address",
      reason = estatus,
    })
    user.emails = emails
    for _, t in ipairs (emails) do
      if t.primary then
        user.email = t.email
      end
    end
  end
  return setmetatable ({
    server    = server,
    token     = token,
    user      = user,
  }, Client)
end

function Client.ardoises (client, what)
  assert (getmetatable (client) == Client)
  assert (what == nil or type (what) == "string")
  local coroutine = Coromake ()
  local threads   = 1
  local results   = {}
  local tag       = Mime.b64 "https://github.com/ardoises"
  Copas.addthread (function ()
    local url   = "https://api.github.com/search/code"
               .. "?per_page=100"
               .. "&sort=updated"
               .. "&order=desc"
               .. "&q=" .. (what and what .. "+" or "") .. tag .. "+language=Lua+filename:readme"
    repeat
      local answer, status, headers = Http {
        url     = url,
        method  = "GET",
        headers = {
          ["Accept"       ] = Client.accept,
          ["User-Agent"   ] = Client.user_agent,
          ["Authorization"] = "token " .. client.token,
        },
      }
      assert (status == 200, {
        error  = "cannot obtain search results",
        reason = status,
      })
      for _, item in ipairs (answer.items) do
        threads = threads+1
        Copas.addthread (function ()
          local repository, repository_status = Http {
            url     = "https://api.github.com/repos/" .. item.repository.full_name,
            method  = "GET",
            headers = {
              ["Accept"       ] = Client.accept,
              ["User-Agent"   ] = Client.user_agent,
              ["Authorization"] = "token " .. client.token,
            },
          }
          if repository_status == 200
          and repository.permissions.pull
          and (repository.full_name  :match (what or "")
            or repository.description:match (what or ""))
          then
            local result  = setmetatable (repository, Ardoise)
            result.client = client
            results [#results+1] = result
          else
            results [#results+1] = false
          end
          threads = threads-1
        end)
      end
      url = nil
      for link in (headers ["Link"] or ""):gmatch "[^,]+" do
        url = link:match [[<([^>]+)>;%s*rel="next"]] or url
      end
    until not url
    threads = threads-1
  end)
  return coroutine.wrap (function ()
    local i = 1
    while threads ~= 0 do
      while results [i] == nil do
        Copas.sleep (0.01)
      end
      if results [i] then
        coroutine.yield (results [i])
      end
      i = i+1
    end
  end)
end

function Client.create (client, t)
  assert (type (t) == "table")
  local name = Patterns.identifier:match (t.name)
  local repository, status = Http {
    url     = "https://api.github.com/user/repos",
    method  = "POST",
    headers = {
      ["Accept"       ] = Client.accept,
      ["User-Agent"   ] = Client.user_agent,
      ["Authorization"] = "token " .. client.token,
    },
    body    = {
      name          = name [1],
      description   = t.description or "An Ardoise",
      homepage      = t.homepage    or "https://github.com/ardoises",
      private       = t.private,
      has_issues    = true,
      has_wiki      = false,
      has_downloads = false,
      auto_init     = false,
    },
  }
  assert (status == 201, {
    error  = "cannot create ardoise",
    reason = status,
  })
  local path = os.tmpname ()
  assert (os.execute (Et.render ([[
    rm    -rf "<%- directory %>"
    mkdir -p  "<%- directory %>"
  ]], {
    directory = path,
  })))
  local readme = io.open (Et.render ([[<%- directory %>/README.md]], {
    directory = path,
  }), "w")
  readme:write (Et.render ([[
# Ardoise <%- name %>

See documentation in [the reference guide](...).
<!---
Ardoise tag: <%- tag %>
Base64 "https://github.com/ardoises"
-->
]], {
    name = name [1],
    tag  = Mime.b64 "https://github.com/ardoises"
  }))
  readme:close ()
  local url    = Url.parse (repository.clone_url)
  url.user     = client.token
  url.password = "x-oauth-basic"
  assert (os.execute (Et.render ([[
    cd <%- path %>
    git init   --quiet
    git add    README.md
    git commit --quiet \
               --author="<%- name %> <<%- email %>>" \
               --message="Create new ardoise."
    git remote add origin <%- url %> > /dev/null
    git push   --quiet \
               --set-upstream origin master
  ]], {
    url   = Url.build (url),
    path  = path,
    name  = client.user.name,
    email = client.user.email,
  })))
  local result  = setmetatable (repository, Ardoise)
  result.client = client
  return result
end

function Ardoise.delete (ardoise)
  assert (getmetatable (ardoise) == Ardoise)
  local _, status = Http {
    url     = ardoise.url,
    method  = "DELETE",
    headers = {
      ["Accept"       ] = Client.accept,
      ["User-Agent"   ] = Client.user_agent,
      ["Authorization"] = "token " .. ardoise.client.token,
    },
  }
  assert (status == 204, {
    error  = "cannot delete ardoise",
    reason = status,
  })
end

function Client.edit (ardoise)
  assert (getmetatable (ardoise) == Ardoise)
  local client = ardoise.client
  local url    = Url.build {
    scheme = client.server.scheme,
    host   = client.server.host,
    port   = client.server.port,
    path   = Et.render ("/editors/<%- repository %>/<%- branch %>", {
      repository = ardoise.full_name,
      branch     = ardoise.branch or ardoise.default_branch,
    }),
  }
  local wsurl, status, headers
  for _ = 1, 60 do
    _, status, headers = Http {
      redirect = false,
      url      = url,
      method   = "GET",
      headers  = {
        ["Accept"       ] = Client.accept,
        ["User-Agent"   ] = Client.user_agent,
        ["Authorization"] = "token " .. client.token,
      },
    }
    if status == 302 and headers.location:match "^wss?://" then
      wsurl = headers.location
      break
    elseif status == 302 then
      url = headers.location
    end
    Copas.sleep (1)
  end
  assert (wsurl, {
    error  = "cannot open websocket connection",
    reason = status,
  })
  local websocket = Websocket.client.copas {}
  assert (websocket:connect (wsurl, "ardoise"))
  assert (websocket:send (Json.encode {
    id    = 1,
    type  = "authenticate",
    token = client.token,
  }))
  local answer = assert (websocket:receive ())
  answer = Json.decode (answer)
  assert (answer.success, {
    error  = "cannot authenticate",
    reason = answer.reason,
  })
  local editor = setmetatable ({
    Layer     = setmetatable ({}, { __index = Layer }),
    ardoise   = ardoise,
    client    = client,
    url       = wsurl,
    websocket = websocket,
    running   = true,
    layers    = {},
    requests  = {},
    answers   = {},
    current   = nil,
  }, Editor)
  editor.Layer.require = function (name)
    if not Patterns.require:match (name) then
      name = name .. "@" .. editor.current
    end
    local layer = editor.layers [name]
    if layer then
      return layer.proxy, layer.ref
    end
    local co = coroutine.running ()
    local module
    local id = #editor.requests+1
    editor.requests [id] = {
      module   = module,
      callback = function (x)
        module = x.answer.code
        Copas.wakeup (co)
      end,
    }
    assert (editor.websocket:send (Json.encode {
      id     = id,
      type   = "require",
      module = module,
    }))
    Copas.sleep (-math.huge)
    editor.requests [id] = nil
    -- local layer, ref = editor:load (t.module, { name = module })
    -- Layer.loaded [module] = layer
    return layer, ref
  end
  editor.receiver = Copas.addthread (function ()
    while editor.running do
      pcall (Editor.receive, editor)
    end
  end)
  editor.patcher  = Copas.addthread (function ()
    while editor.running do
      pcall (Editor.patch, editor)
    end
  end)
  return editor
end

function Editor.receive (editor)
  assert (getmetatable (editor) == Editor)
  local message = editor.websocket:receive ()
  if not message then
    return
  end
  message = Json.decode (message)
  if message.type == "answer" then
    editor.requests [message.id].callback (message)
  elseif message.type == "update" then
    -- local layer = assert (editor:load (message.patch, { within = editor.remote }))
    -- Layer.merge (layer, editor.base.layer)
    -- local refines = editor.remote.layer [Layer.key.refines]
    -- refines [2]   = nil
  end
end

function Editor.wait (editor, condition)
  assert (getmetatable (editor) == Editor)
  assert (condition == nil or type (condition) == "function")
  local co = coroutine.running ()
  local t  = {}
  t.observer = Layer.observe (editor.remote.layer, function (coroutine, proxy, key, value)
    if condition and condition (proxy, key, value) then
      t.observer:disable ()
      coroutine.yield ()
      Copas.addthread (function ()
        Copas.wakeup (co)
      end)
    end
  end)
  Copas.sleep (-math.huge)
end

function Editor.update (editor, f)
  assert (getmetatable (editor) == Editor)
  local created, err = editor:load (f, { within = editor.current })
  if not created then
    error (err)
  end
  local patch   = type (f) == "string"
              and f
               or Layer.dump (created)
  editor.requests [#editor.requests+1] = {
    source   = f,
    patch    = patch,
    callback = function (answer)
      editor.answers [#editor.answers+1] = answer
      Copas.wakeup (editor.patcher)
    end,
  }
  editor.websocket:send (Json.encode {
    id    = #editor.requests,
    type  = "patch",
    patch = patch,
  })
end

function Editor.patch (editor)
  local answer = editor.answers [1]
  if answer then
    if answer.success then
      local request = assert (editor.requests [answer.id])
      local layer   = assert (editor:load (request.source, { within = editor.remote }))
      Layer.merge (layer, editor.base.layer)
    end
    local refines = editor.current.layer [Layer.key.refines]
    for i = 2, Layer.len (refines) do
      refines [i] = refines [i+1]
    end
    editor.requests [answer.id] = nil
    table.remove (editor.answers, 1)
  else
    Copas.sleep (-math.huge)
  end
end

function Editor.__call (editor, f)
  assert (getmetatable (editor) == Editor)
  return editor:update (f)
end

function Editor.require (editor, x)
  assert (getmetatable (editor) == Editor)
  local t = Patterns.require:match (x)
  if not t then
    error { reason = "invalid module" }
  end
  local module = t [1]
  local repo   = t [2]
  assert (websocket:send (Json.encode {
    id     = 1,
    type   = "require",
    module = x,
  }))
  local received = assert (websocket:receive ())
  received = Json.decode (received)
  assert (answer.success, {
    error  = "cannot authenticate",
    reason = received.reason,
  })
  local code = received.answer.code
  local loaded, err_loaded = _G.load (code, x, "t", _ENV)
  if not loaded then
    error { reason = "invalid layer: " .. err_loaded }
  end
  local ok, chunk = pcall (loaded)
  if not ok then
    error { error = "invalid layer: " .. chunk }
  end
  local remote, ref = Layer.new {
    name = x,
  }
  local oldcurrent = editor.current
  editor.current = repo
  local ok_apply, err_apply = pcall (chunk, editor.Layer, remote, ref)
  if not ok_apply then
    error { error = "invalid layer: " .. err_apply }
  end
  editor.current = oldcurrent
  local layer = Layer.new {
    temporary = true,
  }
  layer [Layer.key.refines] = { remote }
  Layer.write_to (layer, false) -- read-only
  repository.modules [module] = {
    layer  = layer,
    remote = remote,
    ref    = ref,
    code   = code,
  }
  return repository.modules [module]
end

function Editor.load (editor)
  assert (getmetatable (editor) == Editor)
  assert (options == nil or type (options) == "table")
  options = options or {}
  if options.within then
    assert (getmetatable (options.within.layer) == Layer.Proxy)
    assert (getmetatable (options.within.ref  ) == Layer.Reference)
  end
  assert (type (patch.code) == "string"
       or type (patch.code) == "function", {
    error  = "cannot load patch",
    reason = "code is neither a string nor a function",
  })
  local code
  if type (patch.code) == "string" then
    local chunk, err_chunk = _G.load (patch.code, patch.module, "t", _ENV)
    if not chunk then
      error { reason = err_chunk }
    end
    local ok_loaded, loaded = pcall (chunk)
    if not ok_loaded then
      error { reason = loaded }
    end
    code = loaded
  elseif type (patch.code) == "function" then
    code = patch.code
  end



  local ok_apply, err_apply = pcall (code, editor.Layer, module.layer, module.ref)
  if not ok_apply then
    error { reason = err_apply }
  end
  local layer, ref
  if options.within then
    layer, ref = Layer.new {
      name      = options.name,
      temporary = true,
    }, options.within.ref
    local refines = options.within.layer [Layer.key.refines]
    refines [Layer.len (refines)+1] = layer
    local old = Layer.write_to (options.within.layer, layer)
    ok, err = pcall (loaded, editor.Layer, options.within.layer, options.within.ref)
    Layer.write_to (options.within.layer, old)
  else
    layer, ref = Layer.new {
      name      = options.name,
      temporary = false,
    }
    ok, err = pcall (loaded, editor.Layer, layer, ref)
  end
  if not ok then
    return nil, err
  end
  return layer, ref
end

function Editor.close (editor)
  assert (getmetatable (editor) == Editor)
  editor.running = false
  editor.websocket:close ()
  Copas.wakeup (editor.receiver)
  Copas.wakeup (editor.patcher)
end

return Client
