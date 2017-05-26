local Coromake  = require "coroutine.make"
local Copas     = require "copas"
local Gettime   = os.time
local Http      = require "ardoises.jsonhttp.copas"
local Json      = require "rapidjson"
local Layer     = require "layeredata"
local Lustache  = require "lustache"
local Patterns  = require "ardoises.patterns"
local Sandbox   = require "ardoises.sandbox"
local Url       = require "net.url"
local Websocket = require "websocket"

if Copas.receive then
  -- FIXME: need to patch copas.receive to make some calls non-blocking.
  -- I do not know why.
  local receive = Copas.receive
  function Copas.receive (client, ...)
    client:settimeout (0)
    return receive (client, ...)
  end
end

local Client   = {}
local Ardoise  = {}
local Ardoises = {}
local Tool     = {}
local Tools    = {}
local Editor   = {}

Client .__index = Client
Ardoise.__index = Ardoise
Editor .__index = Editor

Client.user_agent = "Ardoises Client"

local Mt = {}
setmetatable (Client, Mt)

function Mt.__call (_, options)
  if type (options) ~= "table" then
    return nil, "argument must be a table"
  end
  if type (options.server) ~= "string"
  or not Url.parse (options.server).scheme
  or not Url.parse (options.server).host then
    return nil, "argument.server must be a valid URL"
  end
  if type (options.token) ~= "string" then
    return nil, "argument.token must be a string"
  end
  local token   = options.token
  local server  = Url.parse (options.server)
  local headers = {
    ["Accept"       ] = "application/json",
    ["User-Agent"   ] = Client.user_agent,
    ["Authorization"] = "token " .. token,
  }
  local user, status = Http {
    url      =  Url.build {
      scheme = server.scheme,
      host   = server.host,
      port   = server.port,
      path   = "/my/user",
    },
    method   = "GET",
    headers  = headers,
  }
  if status ~= 200 then
    return nil, "authentication failure: " .. tostring (status)
  end
  local client = setmetatable ({
    server   = server,
    token    = token,
    user     = user,
    headers  = headers,
    -- ardoises = setmetatable ({}, Ardoises),
    -- tools    = setmetatable ({}, Tools),
  }, Client)
  client.ardoises = setmetatable ({
    client = client,
    data   = {},
  }, Ardoises)
  client.tools    = setmetatable ({
    client = client,
    data   = {},
  }, Tools)
  return client
end

function Client.__tostring (client)
  assert (getmetatable (client) == Client)
  return client.user.login .. "@" .. Url.build (client.server)
end

function Client.test (f)
  return function ()
    local ok, err
    for line in io.lines ".environment" do
      local key, value = line:match "^([%w_]+)=(.*)$"
      if key and value then
        _G [key] = value
      end
    end
    Copas.addthread (function ()
      local client = Client {
        server = _G.ARDOISES_SERVER,
        token  = _G.ARDOISES_TOKEN,
      }
      local ardoise = client.ardoises ["-/-:-"]
      local editor  = ardoise:edit ()
      ok, err = pcall (f, editor)
      editor:close ()
    end)
    Copas.loop ()
    return ok or error (err)
  end
end

function Ardoises.refresh (ardoises)
  assert (getmetatable (ardoises) == Ardoises)
  local client = ardoises.client
  local infos, status = Http {
    url     = Url.build {
      scheme = client.server.scheme,
      host   = client.server.host,
      port   = client.server.port,
      path   = "/my/ardoises",
    },
    method  = "GET",
    headers = client.headers,
  }
  if status ~= 200 then
    return nil, "unable to obtain repositories: " .. tostring (status)
  end
  local data = {}
  for _, info in pairs (infos) do
    for _, branch in ipairs (info.repository.branches) do
      local key = Lustache:render ("{{{owner}}}/{{{repository}}}:{{{branch}}}", {
        owner      = info.repository.owner.login,
        repository = info.repository.name,
        branch     = branch.name,
      })
      local ardoise = ardoises.data
                  and ardoises.data [key]
                   or setmetatable ({}, Ardoise)
      ardoise.client       = client
      ardoise.repository   = info.repository
      ardoise.collaborator = info.collaborator
      ardoise.branch       = branch
      data [key] = ardoise
    end
  end
  ardoises.data = data
end

function Ardoises.__call (ardoises)
  assert (getmetatable (ardoises) == Ardoises)
  Ardoises.refresh (ardoises)
  local coroutine = Coromake ()
  return coroutine.wrap (function ()
    for _, ardoise in pairs (ardoises.data) do
      coroutine.yield (ardoise)
    end
  end)
end

function Ardoises.__index (ardoises, key)
  assert (getmetatable (ardoises) == Ardoises)
  local t = assert (Patterns.branch:match (key) or Patterns.require:match (key))
  Ardoises.refresh (ardoises)
  key = t.full_name
  if t.owner == "-" and not ardoises.data [key] then
    ardoises.data [key] = setmetatable ({
      client       = ardoises.client,
      collaborator = {},
      branch       = { name = t.branch },
      repository   = {
        owner          = { login = t.owner },
        name           = t.repository,
        full_name      = t.full_name,
        default_branch = t.branch,
        permissions    = {
          admin = true,
          push  = true,
          pull  = true,
        },
      },
    }, Ardoise)
  end
  return ardoises.data [key]
end

function Ardoises.__newindex (ardoises)
  assert (getmetatable (ardoises) == Ardoises)
  assert (false)
end

function Tools.refresh (tools)
  assert (getmetatable (tools) == Tools)
  local client = tools.client
  local infos, status = Http {
    url     = Url.build {
      scheme = client.server.scheme,
      host   = client.server.host,
      port   = client.server.port,
      path   = "/my/tools",
    },
    method  = "GET",
    headers = client.headers,
  }
  if status ~= 200 then
    return nil, "unable to obtain tools: " .. tostring (status)
  end
  local data = {}
  for _, info in pairs (infos) do
    local tool = tools.data
             and tools.data [info.id]
              or setmetatable ({}, Tool)
    tool.client = client
    tool.id     = info.id
    tool.layer  = info.layer
    tool.image  = info.image
    tool.token  = info.token
    data [info.id] = tool
  end
  tools.data = data
end

function Tools.__call (tools)
  assert (getmetatable (tools) == Tools)
  Ardoises.refresh (tools)
  local coroutine = Coromake ()
  return coroutine.wrap (function ()
    for _, tool in pairs (tools.data) do
      coroutine.yield (tool)
    end
  end)
end

function Tools.__index (tools, key)
  assert (getmetatable (tools) == Tools)
  Ardoises.refresh (tools)
  return tools.data [key]
end

function Tools.launch (tools, value)
  assert (getmetatable (tools) == Tools)
  local client = tools.client
  local info, status = Http {
    url     = Url.build {
      scheme = client.server.scheme,
      host   = client.server.host,
      port   = client.server.port,
      path   = "/tools/",
    },
    body    = {
      layer = value.layer,
      image = value.image,
    },
    method  = "POST",
    headers = client.headers,
  }
  if status ~= 201 then
    return nil, "unable to create tool: " .. tostring (status)
  end
  return client.tools [info.tool.id]
end

function Tool.delete (tool)
  assert (getmetatable (tool) == Tool)
  local client = tool.client
  local _, status = Http {
    url     = Url.build {
      scheme = client.server.scheme,
      host   = client.server.host,
      port   = client.server.port,
      path   = "/tools/" .. tostring (tool.id),
    },
    method  = "DELETE",
    headers = client.headers,
  }
  if status ~= 204 then
    return nil, "unable to delete tool: " .. tostring (status)
  end
  return true
end

function Tool.__tostring (tool)
  assert (getmetatable (tool) == Tool)
  return tool.client.user.login
      .. "@" .. Url.build (tool.client.server)
      .. ": "
      .. Lustache:render ("{{{id}}}={{{image}}}*{{{layer}}}", tool)
end

function Ardoise.__tostring (ardoise)
  assert (getmetatable (ardoise) == Ardoise)
  return ardoise.client.user.login
      .. "@" .. Url.build (ardoise.client.server)
      .. ": "
      .. Lustache:render ("{{{owner}}}/{{{repository}}}:{{{branch}}}", {
        owner      = ardoise.repository.owner.login,
        repository = ardoise.repository.name,
        branch     = ardoise.branch.name,
      })
end

function Ardoise.edit (ardoise)
  assert (getmetatable (ardoise) == Ardoise)
  local client    = ardoise.client
  local websocket = Websocket.client.copas {}
  local start     = Gettime ()
  local info
  repeat
    assert (Gettime () - start <= 60)
    local status
    info, status = Http {
      method  = "GET",
      headers = client.headers,
      url     = Url.build {
        scheme = client.server.scheme,
        host   = client.server.host,
        port   = client.server.port,
        path   = Lustache:render ("/editors/{{{owner}}}/{{{repository}}}/{{{branch}}}", {
          owner      = ardoise.repository.owner.login,
          repository = ardoise.repository.name,
          branch     = ardoise.branch.name,
        }),
      },
    }
    assert (status == 200)
  until info.editor_url
  repeat
    local connected = websocket:connect (info.editor_url, "ardoise", {
      mode        = "client",
      protocol    = "tlsv1_2",
      verify      = "none",
    })
    if not connected then
      Copas.sleep (1)
    end
  until connected
  assert (websocket:send (Json.encode {
    id    = "authenticate",
    type  = "authenticate",
    token = info.token,
  }))
  local res = assert (websocket:receive ())
  res = Json.decode (res)
  if not res.success then
    return nil, "authentication failure"
  end
  local editor = setmetatable ({
    Layer       = setmetatable ({}, { __index = Layer }),
    ardoise     = ardoise,
    client      = client,
    url         = info.editor_url,
    websocket   = websocket,
    running     = true,
    modules     = {},
    requests    = {},
    callbacks   = {},
    answers     = {},
    observers   = {},
    permissions = res.answer,
    current     = Lustache:render ("{{{owner}}}/{{{repository}}}:{{{branch}}}", {
      owner      = ardoise.repository.owner.login,
      repository = ardoise.repository.name,
      branch     = ardoise.branch.name,
    }),
  }, Editor)
  editor.receiver = Copas.addthread (function ()
    while editor.running do
      pcall (Editor.answer, editor)
    end
  end)
  editor.Layer.require = function (name)
    if not Patterns.require:match (name) then
      name = name .. "@" .. assert (editor.current)
    end
    local result, err = editor:require (name)
    if not result then
      error (err)
    end
    return result.layer, result.ref
  end
  return editor
end

function Editor.send (editor, data)
  assert (editor.websocket.state == "OPEN")
  return editor.websocket:send (Json.encode (data))
end

function Editor.receive (editor)
  local result = editor.websocket:receive ()
  if result then
    result = assert (Json.decode (result))
    return result
  end
end

function Editor.__tostring (editor)
  assert (getmetatable (editor) == Editor)
  return tostring (editor.ardoise)
end

function Editor.list (editor)
  assert (getmetatable (editor) == Editor)
  local co       = coroutine.running ()
  local request  = {
    id   = #editor.requests+1,
    type = "list",
  }
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = function ()
    Copas.wakeup (co)
  end
  assert (editor:send (request))
  repeat
    Copas.sleep (-math.huge)
  until request.answer
  local coroutine = Coromake ()
  return coroutine.wrap (function ()
    for name, module in pairs (request.answer) do
      editor.modules [module] = editor.modules [module] or true
      coroutine.yield (name, module)
    end
  end)
end

function Editor.require (editor, name)
  assert (getmetatable (editor) == Editor)
  if Patterns.module:match (name) then
    name = name .. "@" .. assert (editor.current)
  end
  local module = Patterns.require:match (name)
  if not module then
    return nil, "invalid module"
  end
  if editor.modules [module.name] == false then
    return nil, "module not found"
  elseif editor.modules [module.name]
     and editor.modules [module.name] ~= true then
    return editor.modules [module.name]
  end
  local co       = coroutine.running ()
  local request  = {
    id     = #editor.requests+1,
    type   = "require",
    module = module.name,
  }
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = function ()
    Copas.wakeup (co)
  end
  assert (editor:send (request))
  repeat
    Copas.sleep (-math.huge)
  until request.success ~= nil
  if not request.success then
    return nil, request.error
  end
  local code = request.answer.code
  local loaded, err_loaded = _G.load (code, module.name, "t", Sandbox)
  if not loaded then
    return nil, "invalid layer: " .. tostring (err_loaded)
  end
  local ok, chunk = pcall (loaded)
  if not ok then
    return nil, "invalid layer: " .. tostring (chunk)
  end
  local remote, ref = Layer.new {
    name = module.name,
  }
  local oldcurrent = editor.current
  editor.current   = Lustache:render ("{{{owner}}}/{{{repository}}}:{{{branch}}}", module)
  local ok_apply, err_apply = pcall (chunk, editor.Layer, remote, ref)
  if not ok_apply then
    return nil, "invalid layer: " .. tostring (err_apply)
  end
  editor.current = oldcurrent
  local layer = Layer.new {
    temporary = true,
  }
  layer [Layer.key.refines] = { remote }
  Layer.write_to (layer, false) -- read-only
  editor.modules [module.name] = {
    name   = module.name,
    layer  = layer,
    remote = remote,
    ref    = ref,
    code   = code,
  }
  return editor.modules [module.name]
end

function Editor.create (editor, name)
  assert (getmetatable (editor) == Editor)
  if Patterns.module:match (name) then
    name = name .. "@" .. assert (editor.current)
  end
  local module = Patterns.require:match (name)
  if not module then
    return nil, "invalid module"
  end
  if editor.modules [module.name] then
    return nil, "module exists already"
  end
  local remote, ref = Layer.new {
    name = module.name,
  }
  local layer = Layer.new {
    temporary = true,
  }
  layer [Layer.key.refines] = { remote }
  Layer.write_to (layer, false) -- read-only
  editor.modules [module.name] = {
    name   = module.name,
    layer  = layer,
    remote = remote,
    ref    = ref,
    code   = [[return function (Layer, layer, ref) end]],
  }
  local request = {
    id     = #editor.requests+1,
    type   = "create",
    module = module.name,
    code   = [[return function (Layer, layer, ref) end]],
  }
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = function ()
    if not request.success then
      editor.modules [module.name] = nil
    end
  end
  assert (editor:send (request))
  return module.name
end

function Editor.delete (editor, name)
  assert (getmetatable (editor) == Editor)
  if Patterns.module:match (name) then
    name = name .. "@" .. assert (editor.current)
  end
  local module = Patterns.require:match (name)
  if not module then
    return nil, "invalid module"
  end
  if not editor.modules [module.name] then
    return nil, "module does not exist"
  end
  local back = editor.modules [module.name]
  editor.modules [module.name] = nil
  local request = {
    id     = #editor.requests+1,
    type   = "delete",
    module = module.name,
  }
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = function ()
    if request.success then
      editor.modules [module.name] = nil
    else
      editor.modules [module.name] = back
    end
  end
  assert (editor:send (request))
  return true
end

function Editor.patch (editor, what)
  assert (getmetatable (editor) == Editor)
  if type (what) ~= "table" then
    return nil, "argument must be a table"
  end
  local modules = {}
  local function rollback ()
    for _, module in pairs (editor.modules) do
      if type (module) == "table" then
        if module.current then
          Layer.write_to (module.layer, nil)
          local refines = module.layer [Layer.key.refines]
          refines [Layer.len (refines)] = nil
        end
        Layer.write_to (module.layer, false)
        module.current = nil
      end
    end
  end
  for name, code in pairs (what) do
    if  not Patterns.require:match (name)
    and Patterns.module:match (name) then
      name = name .. "@" .. assert (editor.current)
    end
    local module = editor:require (name)
    if not module then
      return nil, "unknown module: " .. tostring (name)
    end
    if type (code) == "string" then
      local chunk, err_chunk = _G.load (code, name, "t", Sandbox)
      if not chunk then
        return nil, "invalid patch: " .. tostring (err_chunk)
      end
      local ok_loaded, loaded = pcall (chunk)
      if not ok_loaded then
        return nil, "invalid patch: " .. tostring (loaded)
      end
      code = loaded
    elseif type (code) == "function" then
      code = code
    end
    module.current = Layer.new {
      temporary = true,
    }
    modules [module] = {
      code    = code,
      current = module.current,
    }
    Layer.write_to (module.layer, nil)
    local refines = module.layer [Layer.key.refines]
    refines [Layer.len (refines)+1] = module.current
    Layer.write_to (module.layer, module.current)
    local ok_apply, err_apply = pcall (code, editor.Layer, module.layer, module.ref)
    Layer.write_to (module.layer, false)
    if not ok_apply then
      rollback ()
      return nil, err_apply
    end
  end
  -- send patches
  local request = {
    id      = #editor.requests+1,
    type    = "patch",
    patches = {},
  }
  for module in pairs (modules) do
    local dumped, err = Layer.dump (module.current)
    if not dumped then
      rollback ()
      return nil, "unable to dump patch: " .. tostring (err)
    end
    request.patches [#request.patches+1] = {
      module = module.name,
      code   = dumped,
    }
    module.current = nil
  end
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = function ()
    for module, t in pairs (modules) do
      Layer.write_to (module.layer, nil)
      local refines = module.layer [Layer.key.refines]
      for i, l in ipairs (refines or {}) do
        if t.current == l then
          for j = i+1, #refines do
            refines [j-1] = refines [j]
          end
          refines [#refines] = nil
        end
      end
      Layer.write_to (module.layer, false)
    end
    if not request.success then
      return nil, request.error
    end
    for module, t in pairs (modules) do
      local layer   = Layer.new { temporary = true }
      local current = Layer.new { temporary = true }
      layer [Layer.key.refines] = {
        module.remote,
        current,
      }
      Layer.write_to (layer, current)
      t.code (editor.Layer, layer, module.ref)
      Layer.merge (current, module.remote)
      module.code = Layer.dump (module.remote)
    end
  end
  assert (editor:send (request))
  return true
end

function Editor.answer (editor)
  assert (getmetatable (editor) == Editor)
  local message = editor:receive ()
  if not message then
    return
  end
  if message.type == "ping" then
    editor:send {
      id   = message.id,
      type = "pong",
    }
  elseif message.type == "pong" then
    local _ = false
  elseif message.type == "answer" then
    local request  = editor.requests  [message.id]
    local callback = editor.callbacks [message.id]
    for k, v in pairs (request) do
      message [k] = v
    end
    request.success = message.success
    request.answer  = message.answer
    request.error   = message.error
    editor.requests  [message.id] = nil
    editor.callbacks [message.id] = nil
    assert (pcall (callback))
  elseif message.type == "create" then
    editor.modules [message.module] = true
  elseif message.type == "delete" then
    editor.modules [message.module] = nil
  elseif message.type == "patch" then
    for _, patch in ipairs (message.patches) do
      local module = editor.modules [patch.module]
      if module then
        local chunk, err_chunk = _G.load (patch.code, module.name, "t", Sandbox)
        if not chunk then
          return nil, "invalid patch: " .. tostring (err_chunk)
        end
        local ok_loaded, loaded = pcall (chunk)
        if not ok_loaded then
          return nil, "invalid patch: " .. tostring (loaded)
        end
        local layer   = Layer.new { temporary = true }
        local current = Layer.new { temporary = true }
        layer [Layer.key.refines] = {
          module.remote,
          current,
        }
        Layer.write_to (layer, current)
        loaded (editor.Layer, layer, module.ref)
        Layer.merge (current, module.remote)
        module.code = Layer.dump (module.remote)
      end
    end
  end
  for observer in pairs (editor.observers) do
    observer (message)
  end
end

function Editor.events (editor, t)
  assert (getmetatable (editor) == Editor)
  local function call (what)
    if not editor.running then
      return
    end
    what.co        = Copas.running
    what.active    = true
    what.result    = nil
    what.observers = {}
    for name, f in pairs (t or {}) do
      local module = editor:require (name)
      if module then
        what.observers [#what.observers+1] = Layer.observe (module.remote, function (_coroutine, proxy, key, value)
          if f == true or f (proxy, key, value) then
            local r = {
              type      = "update",
              proxy     = proxy,
              key       = key,
              old_value = value,
            }
            value = _coroutine.yield ()
            r.new_value = value
            what.result = r
            Copas.wakeup (what.co)
          end
        end)
      end
    end
    what.observer = function (message)
      what.result = message
      Copas.wakeup (what.co)
    end
    editor.observers [what.observer] = true
    Copas.sleep (-math.huge)
    return what.active and what.result or nil
  end
  local function clean (what)
    editor.observers [what.observer] = nil
    for _, observer in ipairs (what.observers) do
      observer:disable ()
    end
    what.active    = nil
    what.observer  = nil
    what.observers = nil
  end
  return setmetatable ({}, {
    __call = call,
    __gc   = clean,
  })
end

function Editor.__call (editor, t)
  assert (getmetatable (editor) == Editor)
  return editor:patch (t)
end

function Editor.close (editor)
  assert (getmetatable (editor) == Editor)
  editor.running = false
  editor.websocket:close ()
  Copas.wakeup (editor.receiver)
end

return Client
