local Coromake  = require "coroutine.make"
_G.coroutine    = Coromake ()
local Copas     = require "copas"
local Et        = require "etlua"
local Json      = require "cjson"
local Mime      = require "mime"
local Url       = require "socket.url"
local Layer     = require "layeredata"
local Http      = require "ardoises.jsonhttp".copas
local Patterns  = require "ardoises.patterns"
local Websocket = require "websocket"

local Client  = {}
local Ardoise = {}
local Editor  = {}

Client .__index = Client
Ardoise.__index = Ardoise
Editor .__index = Editor

Client.accept     = "application/vnd.github.v3+json"
Client.user_agent = "Ardoises Client"
Client.tag        = Mime.b64 "https://github.com/ardoises"

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
    return nil, "argument.token must be an authentication token"
  end
  local server = Url.parse (options.server)
  local token  = options.token
  local user, status = Http {
    url      = "https://api.github.com/user",
    method   = "GET",
    headers  = {
      ["Accept"       ] = Client.accept,
      ["User-Agent"   ] = Client.user_agent,
      ["Authorization"] = "token " .. token,
    },
  }
  if status ~= 200 then
    return nil, "authentication failure: " .. tostring (status)
  end
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
    if estatus ~= 200 then
      return nil, "unable to obtain email address: " .. tostring (status)
    end
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

function Client.__tostring (client)
  assert (getmetatable (client) == Client)
  return client.token .. "@" .. Url.build (client.server)
end

function Client.ardoise (client, what)
  assert (getmetatable (client) == Client)
  if type (what) ~= "string" then
    return nil, "argument must be a string"
  end
  what = Patterns.branch:match (what) or Patterns.repository:match (what)
  if not what then
    return nil, "argument must be in format: 'owner/repository(:branch)?'"
  end
  local repository, status = Http {
    url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>", what),
    method  = "GET",
    headers = {
      ["Accept"       ] = Client.accept,
      ["User-Agent"   ] = Client.user_agent,
      ["Authorization"] = "token " .. client.token,
    },
  }
  if status ~= 200 then
    return nil, "unable to obtain repository: " .. tostring (status)
  end
  if not repository.permissions.pull then
    return nil, "unable to read repository"
  end
  local result  = setmetatable (repository, Ardoise)
  result.branch = what.branch or result.default_branch
  result.client = client
  return result
end

function Client.ardoises (client, what)
  assert (getmetatable (client) == Client)
  if what ~= nil and type (what) ~= "string" then
    return nil, "argument must be either nil or a string"
  end
  local coroutine = Coromake ()
  local threads   = 1
  local results   = {}
  Copas.addthread (function ()
    local url   = "https://api.github.com/search/code"
               .. "?per_page=100"
               .. "&sort=updated"
               .. "&order=desc"
               .. "&q=" .. (what and what .. "+" or "") .. Client.tag .. "+language=Lua+filename:readme"
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
      if status ~= 200 then
        return nil, "unable to obtain search results: " .. tostring (status)
      end
      for _, item in ipairs (answer.items) do
        threads = threads+1
        Copas.addthread (function ()
          local repository = client:ardoise (item.repository.full_name)
          if repository then
            results [#results+1] = setmetatable (repository, Ardoise)
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

function Client.create (client, what, options)
  assert (getmetatable (client) == Client)
  options = options or {}
  if type (what) ~= "string" then
    return nil, "argument must be a string"
  end
  what = Patterns.branch:match (what) or Patterns.repository:match (what)
  if not what then
    return nil, "arguement must be in format: 'owner/repository(:branch)?'"
  end
  local create_url
  if what.owner.id == client.user.id then
    create_url = "https://api.github.com/user/repos"
  else
    create_url = Et.render ("https://api.github.com/orgs/<%- org %>/repos", {
      org = what.owner,
    })
  end
  local repository, status = Http {
    url     = create_url,
    method  = "POST",
    headers = {
      ["Accept"       ] = Client.accept,
      ["User-Agent"   ] = Client.user_agent,
      ["Authorization"] = "token " .. client.token,
    },
    body    = {
      name          = what.repository,
      description   = options.description or "An Ardoise",
      homepage      = options.homepage    or "https://github.com/ardoises",
      private       = options.private,
      has_issues    = true,
      has_wiki      = false,
      has_downloads = false,
      auto_init     = false,
    },
  }
  if status ~= 201 then
    return nil, "unable to create ardoise: " .. tostring (status)
  end
  repository.branch = what.branch or repository.default_branch
  local path = os.tmpname ()
  assert (os.execute (Et.render ([[
    rm    -rf "<%- directory %>"
    mkdir -p  "<%- directory %>"
  ]], {
    directory = path,
  })))
  local readme = assert (io.open (Et.render ([[<%- directory %>/README.md]], {
    directory = path,
  }), "w"))
  readme:write (Et.render ([[
# Ardoise <%- name %>

See documentation in [the reference guide](...).
<!---
Ardoise tag: <%- tag %>
Base64 "https://github.com/ardoises"
-->
]], {
    name = repository.name,
    tag  = Mime.b64 "https://github.com/ardoises"
  }))
  readme:close ()
  local url    = Url.parse (repository.clone_url)
  url.user     = client.token
  url.password = "x-oauth-basic"
  assert (os.execute (Et.render ([[
    cd <%- path %>
    git init     --quiet
    git checkout -b "<%- branch %>"
    git add      README.md
    git commit   --quiet \
                 --author="<%- name %> <<%- email %>>" \
                 --message="Create new ardoise."
    git remote   add origin <%- url %> > /dev/null
    git push     --quiet \
                 --set-upstream origin "<%- branch %>"
  ]], {
    url    = Url.build (url),
    path   = path,
    name   = client.user.name,
    email  = client.user.email,
    branch = repository.branch,
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
  if status ~= 204 then
    return nil, "unable to delete ardoise: " .. tostring (status)
  end
  return true
end

function Ardoise.__tostring (ardoise)
  assert (getmetatable (ardoise) == Ardoise)
  return Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", {
    owner      = ardoise.owner.login,
    repository = ardoise.name,
    branch     = ardoise.branch,
  })
end

function Ardoise.edit (ardoise)
  assert (getmetatable (ardoise) == Ardoise)
  local client = ardoise.client
  local url    = Url.build {
    scheme = client.server.scheme,
    host   = client.server.host,
    port   = client.server.port,
    path   = Et.render ("/editors/<%- owner %>/<%- repository %>/<%- branch %>", {
      owner      = ardoise.owner.login,
      repository = ardoise.name,
      branch     = ardoise.branch,
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
  if not wsurl then
    return nil, "unable to open websocket connection: " .. tostring (status)
  end
  local websocket = Websocket.client.copas {}
  assert (websocket:connect (wsurl, "ardoise"))
  assert (websocket:send (Json.encode {
    id    = 1,
    type  = "authenticate",
    token = client.token,
  }))
  local res = assert (websocket:receive ())
  res = Json.decode (res)
  if not res.success then
    return nil, "authentication failure"
  end
  local editor = setmetatable ({
    Layer     = setmetatable ({}, { __index = Layer }),
    ardoise   = ardoise,
    client    = client,
    url       = wsurl,
    websocket = websocket,
    running   = true,
    modules   = {},
    requests  = {},
    callbacks = {},
    answers   = {},
    current   = nil,
    observers = {},
  }, Editor)
  assert (websocket:send (Json.encode {
    id   = 1,
    type = "list",
  }))
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

function Editor.list (editor)
  assert (getmetatable (editor) == Editor)
  local request  = {
    id   = #editor.requests+1,
    type = "list",
  }
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = coroutine.running ()
  assert (editor.client.websocket:send (Json.encode (request)))
  Copas.sleep (-math.huge)
  assert (request.answer)
  local coroutine = Coromake ()
  return coroutine.wrap (function ()
    for name, module in pairs (request.answer) do
      coroutine.yield (name, module)
    end
  end)
end

function Editor.require (editor, module)
  assert (getmetatable (editor) == Editor)
  module = Patterns.require:match (module)
  if not module then
    return nil, "invalid module"
  end
  local request  = {
    id     = #editor.requests+1,
    type   = "require",
    module = module.full_name,
  }
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = coroutine.running ()
  assert (editor.websocket:send (Json.encode (request)))
  Copas.sleep (-math.huge)
  if not request.success then
    return nil, request.errors
  end
  local code = request.answer.code
  local loaded, err_loaded = _G.load (code, module.full_name, "t")
  if not loaded then
    return nil, "invalid layer: " .. err_loaded
  end
  local ok, chunk = pcall (loaded)
  if not ok then
    return nil, "invalid layer: " .. chunk
  end
  local remote, ref = Layer.new {
    name = module.full_name,
  }
  local oldcurrent = editor.current
  editor.current   = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", module)
  local ok_apply, err_apply = pcall (chunk, editor.Layer, remote, ref)
  if not ok_apply then
    return nil, "invalid layer: " .. err_apply
  end
  editor.current = oldcurrent
  local layer = Layer.new {
    temporary = true,
  }
  layer [Layer.key.refines] = { remote }
  Layer.write_to (layer, false) -- read-only
  editor.modules [module.full_name] = {
    name   = module.full_name,
    layer  = layer,
    remote = remote,
    ref    = ref,
    code   = code,
  }
  return editor.modules [module.full_name]
end

function Editor.patch (editor, what)
  assert (getmetatable (editor) == Editor)
  if type (what) ~= "table" then
    return nil, "argument must be a table"
  end
  local function rollback ()
    for _, module in pairs (editor.modules) do
      if module.current then
        Layer.write_to (module.layer, nil)
        local refines = module.layer [Layer.key.refines]
        refines [Layer.len (refines)] = nil
      end
      Layer.write_to (module.layer, false)
      module.current = nil
    end
  end
  local modules = {}
  for name, code in pairs (what) do
    local module = editor.modules [name]
    if not module then
      return nil, "unknown module"
    end
    if type (code) == "string" then
      local chunk, err_chunk = _G.load (code, module, "t")
      if not chunk then
        return nil, "invalid patch: " .. err_chunk
      end
      local ok_loaded, loaded = pcall (chunk)
      if not ok_loaded then
        return nil, "invalid patch: " .. loaded
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
      return nil, "unable to dump patch: " .. err
    end
    request.patches [module.name] = dumped
    module.current = nil
  end
  editor.requests  [request.id] = request
  editor.callbacks [request.id] = coroutine.running ()
  assert (editor.client.websocket:send (Json.encode (request)))
  Copas.sleep (-math.huge)
  if not request.success then
    rollback ()
    return nil, request.error
  end
  for module, layer in pairs (modules) do
    Layer.write_to (module.layer, nil)
    local refines = module.layer [Layer.key.refines]
    for i, l in ipairs (refines) do
      if layer == l then
        table.remove (refines, i)
      end
    end
    Layer.write_to (module.layer, false)
    if type (what [module.name] == "string") then
      Layer.merge (layer, module.remote)
    elseif type (what [module.name] == "function") then
      what [module.name] (editor.Layer, module.remote, module.ref)
    else
      assert (false)
    end
  end
  return true
end

function Editor.receive (editor)
  assert (getmetatable (editor) == Editor)
  local message = editor.websocket:receive ()
  if not message then
    return
  end
  message = Json.decode (message)
  if message.type == "answer" then
    local request  = editor.requests  [message.id]
    local callback = editor.callbacks [message.id]
    request.success = message.success
    request.answer  = message.answer
    request.error   = message.error
    editor.requests  [message.id] = nil
    editor.callbacks [message.id] = nil
    Copas.wakeup (callback)
  elseif message.type == "create" then
    for observer in pairs (editor.observer) do
      observer (message)
    end
  elseif message.type == "delete" then
    for observer in pairs (editor.observer) do
      observer (message)
    end
  elseif message.type == "patch" then
    for name, code in pairs (message.patches) do
      local module = editor.modules [name]
      if module then
        local chunk, err_chunk = _G.load (code, module, "t")
        if not chunk then
          return nil, "invalid patch: " .. err_chunk
        end
        local ok_loaded, loaded = pcall (chunk)
        if not ok_loaded then
          return nil, "invalid patch: " .. loaded
        end
        module.current = Layer.new {
          temporary = true,
        }
        loaded (editor.Layer, module.remote, module.ref)
      end
    end
    for observer in pairs (editor.observer) do
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
  return result.type, result.result
end

function Editor.__call (editor, f)
  assert (getmetatable (editor) == Editor)
  return editor:patch (f)
end

function Editor.close (editor)
  assert (getmetatable (editor) == Editor)
  editor.running = false
  editor.websocket:close ()
  Copas.wakeup (editor.receiver)
  Copas.wakeup (editor.patcher)
end

return Client
