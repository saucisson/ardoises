local Coromake  = require "coroutine.make"
local Copas     = require "copas"
local Gettime   = os.time
local Http      = require "ardoises.jsonhttp.copas"
local Json      = require "rapidjson"
local Layer     = require "layeredata"
local Lustache  = require "lustache"
local Patterns  = require "ardoises.patterns"
local Url       = require "net.url"
local Websocket = require "websocket"

local Client  = {}
local Ardoise = {}
local Editor  = {}

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
  if type (options.tokens) ~= "table"
  or type (options.tokens.github  ) ~= "string"
  or type (options.tokens.ardoises) ~= "string" then
    return nil, "argument.token must be a table of tokens { ardoises, github }"
  end
  local server  = Url.parse (options.server)
  local tokens  = options.tokens
  local headers = {
    ["Accept"       ] = "application/json",
    ["User-Agent"   ] = Client.user_agent,
    ["Authorization"] = "token " .. options.tokens.ardoises,
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
  return setmetatable ({
    headers = headers,
    server  = server,
    tokens  = tokens,
    user    = user,
  }, Client)
end

function Client.__tostring (client)
  assert (getmetatable (client) == Client)
  return client.user.login .. "@" .. Url.build (client.server)
end

function Client.ardoises (client)
  assert (getmetatable (client) == Client)
  local ardoises, status = Http {
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
  local result = {}
  for i, ardoise in ipairs (ardoises) do
    result [i] = setmetatable ({
      client       = client,
      repository   = ardoise.repository,
      collaborator = ardoise.collaborator,
      branch       = ardoise.repository.default_branch,
    }, Ardoise)
  end
  return result
end

function Ardoise.__tostring (ardoise)
  assert (getmetatable (ardoise) == Ardoise)
  return ardoise.client.user.login
      .. "@" .. Url.build (ardoise.client.server)
      .. ": "
      .. Lustache:render ("{{{owner}}}/{{{repository}}}:{{{branch}}}", {
        owner      = ardoise.repository.owner.login,
        repository = ardoise.repository.name,
        branch     = ardoise.branch,
      })
end

function Ardoise.on_branch (ardoise, branch)
  assert (getmetatable (ardoise) == Ardoise)
  if type (branch) ~= "string" then
    return nil, "argument branch must be a string"
  end
  return setmetatable ({
    client       = ardoise.client,
    repository   = ardoise.repository,
    collaborator = ardoise.collaborator,
    branch       = branch,
  }, Ardoise)
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
      headers = ardoise.client.headers,
      url     = Url.build {
        scheme = client.server.scheme,
        host   = client.server.host,
        port   = client.server.port,
        path   = Lustache:render ("/editors/{{{owner}}}/{{{repository}}}/{{{branch}}}", {
          owner      = ardoise.repository.owner.login,
          repository = ardoise.repository.name,
          branch     = ardoise.branch,
        }),
      },
    }
    assert (status == 200)
    local connected = websocket:connect (info.editor_url, "ardoise")
    if not connected then
      Copas.sleep (1)
    end
  until connected
  assert (websocket:send (Json.encode {
    id    = "authenticate",
    type  = "authenticate",
    token = client.tokens.github,
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
      branch     = ardoise.branch,
    }),
  }, Editor)
  Copas.addthread (function ()
    while editor.running do
      editor:send {
        id   = "ping",
        type = "ping",
      }
      Copas.sleep (30)
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
  editor.receiver = Copas.addthread (function ()
    while editor.running do
      pcall (Editor.answer, editor)
    end
  end)
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
  Copas.sleep (-math.huge)
  assert (request.answer)
  local coroutine = Coromake ()
  return coroutine.wrap (function ()
    for name, module in pairs (request.answer) do
      editor.modules [module] = true
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
  Copas.sleep (-math.huge)
  if not request.success then
    return nil, request.errors
  end
  local code = request.answer.code
  local loaded, err_loaded = _G.load (code, module.name, "t")
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
    code   = [[ return function () end ]],
  }
  local request = {
    id     = #editor.requests+1,
    type   = "create",
    module = module.name,
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
    if not request.success then
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
      local chunk, err_chunk = _G.load (code, name, "t")
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
    modules [module] = module.current
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
    for module, layer in pairs (modules) do
      Layer.write_to (module.layer, nil)
      local refines = module.layer [Layer.key.refines]
      for i, l in ipairs (refines or {}) do
        if layer == l then
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
    for module, layer in pairs (modules) do
      if type (what [module.name] == "string") then
        Layer.merge (layer, module.remote)
      elseif type (what [module.name] == "function") then
        what [module.name] (editor.Layer, module.remote, module.ref)
      else
        assert (false)
      end
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
    request.success = message.success
    request.answer  = message.answer
    request.error   = message.error
    editor.requests  [message.id] = nil
    editor.callbacks [message.id] = nil
    callback ()
  elseif message.type == "create" then
    editor.modules [message.module] = true
    for observer in pairs (editor.observers) do
      observer (message)
    end
  elseif message.type == "delete" then
    editor.modules [message.module] = nil
    for observer in pairs (editor.observers) do
      observer (message)
    end
  elseif message.type == "patch" then
    for _, patch in ipairs (message.patches) do
      local module = editor.modules [patch.module]
      if module then
        local chunk, err_chunk = _G.load (patch.code, module, "t")
        if not chunk then
          return nil, "invalid patch: " .. tostring (err_chunk)
        end
        local ok_loaded, loaded = pcall (chunk)
        if not ok_loaded then
          return nil, "invalid patch: " .. tostring (loaded)
        end
        module.current = Layer.new {
          temporary = true,
        }
        loaded (editor.Layer, module.remote, module.ref)
      end
    end
    for observer in pairs (editor.observers) do
      observer (message)
    end
  end
end

function Editor.wait (editor, t)
  assert (getmetatable (editor) == Editor)
  local result    = {}
  local co        = coroutine.running ()
  local observers = {}
  for name, f in pairs (t or {}) do
    local module = editor.modules [name]
    if module then
      observers [#observers+1] = Layer.observe (module.remote, function (coroutine, proxy, key, value)
        if f == true or f (proxy, key, value) then
          result.proxy     = proxy
          result.key       = key
          result.old_value = value
          value = coroutine.yield ()
          result.new_value = value
        end
      end)
    end
  end
  local function f (message)
    if     message.type == "create" and t.create then
      result.type   = "create"
      result.result = message.module
    elseif message.type == "delete" and t.delete then
      result.type   = "delete"
      result.result = message.module
    elseif message.type == "update" and t.update and result.proxy then
      result.type   = "update"
      result.result = {
        proxy     = result.proxy,
        key       = result.key,
        old_value = result.old_value,
        new_value = result.new_value,
      }
    end
    Copas.addthread (function ()
      Copas.wakeup (co)
    end)
  end
  editor.observers [f] = true
  Copas.sleep (-math.huge)
  editor.observers [f] = nil
  return result.type, result.result
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
