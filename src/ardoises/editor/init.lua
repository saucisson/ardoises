local Copas     = require "copas"
local Data      = require "ardoises.data"
local Et        = require "etlua"
local Http      = require "ardoises.jsonhttp.copas"
local Json      = require "rapidjson"
local Patterns  = require "ardoises.patterns"
local Sandbox   = require "ardoises.sandbox"
local Url       = require "socket.url"
local Websocket = require "websocket"

-- # Messages
-- { id = ..., type = "authenticate", token = "..." }
-- { id = ..., type = "patch"       , module = ..., code = ... }
-- { id = ..., type = "require"     , module = "..." }
-- { id = ..., type = "list"        }
-- { id = ..., type = "create"      , module = "..." }
-- { id = ..., type = "delete"      , module = "..." }
-- { id = ..., type = "answer"      , success = true|false, reason = "..." }
-- { id = ..., type = "execute"     }

local Mt     = {}
local Editor = setmetatable ({}, Mt)
local Client = {}
Editor.__index = Editor
Client.__index = Client

function Mt.__call (_, options)
  local editor = setmetatable ({
    ardoises_url = assert (options.ardoises),
    branch       = assert (options.branch),
    token        = assert (options.token),
    timeout      = assert (options.timeout),
    port         = assert (options.port),
    application  = assert (options.application),
    nopush       = options.nopush,
    permissions  = nil,
    current      = nil,
    running      = false,
    last         = false,
    clients      = {},
    tasks        = {},
    queue        = {},
    repositories = {}, -- branch.full_name -> module_name -> { ... }
    Data         = setmetatable ({}, { __index = Data }),
  }, Editor)
  local repository
  if editor.branch.owner == "-" then
    repository = {
      owner          = { login = "-" },
      name           = editor.branch.repository,
      full_name      = "-/" .. editor.branch.repository,
      default_branch = editor.branch.branch,
      path           = ".",
      modules        = {},
      permissions    = {
        admin = true,
        push  = true,
        pull  = true,
      },
    }
    editor.port = tonumber (editor.branch.branch)
    editor.repositories [editor.branch.full_name] = repository
  else
    local status
    repository, status = Http {
      url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>", editor.branch),
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. tostring (editor.token),
        ["User-Agent"   ] = editor.application,
      },
    }
    if status ~= 200 then
      return nil, "unable to obtain repository information: " .. tostring (status)
    end
  end
  editor.permissions = repository.permissions
  if not editor.permissions.pull then
    return nil, "missing permission to read repository"
  end
  editor.Data.require = function (name)
    if not Patterns.require:match (name) then
      name = tostring (name) .. "@" .. editor.current
    end
    local result, err = editor:require (name)
    if not result then
      error (err)
    end
    return result.layer, result.ref
  end
  return editor
end

function Editor.start (editor)
  assert (getmetatable (editor) == Editor)
  local repository, err = editor:pull (editor.branch)
  if not repository then
    return nil, err
  end
  local file = assert (io.popen (Et.render ([[ find "<%- path %>/src" -name "*.lua" 2> /dev/null ]], {
    path = repository.path,
  }), "r"))
  repeat
    local line = file:read "*l"
    if line and not line:match "_spec%.lua$" then
      local module = line:match ("^" .. repository.path .. "/src/(.*)%.lua$"):gsub ("/", ".")
      repository.modules [module] = true
    end
  until not line
  local copas_addserver = Copas.addserver
  local addserver       = function (socket, f)
    editor.socket = socket
    editor.host, editor.port = socket:getsockname ()
    copas_addserver (socket, f)
    editor.last    = os.time ()
    editor.running = true
  end
  Copas.addserver = addserver
  editor.server   = Websocket.server.copas.listen {
    port      = editor.port,
    default   = function () end,
    protocols = {
      ardoise = function (ws)
        print "-> client"
        editor.last  = os.time ()
        local client = setmetatable ({
          websocket   = ws,
          token       = nil,
          permissions = {
            read  = nil,
            write = nil,
          },
          handlers    = {
            authenticate = Editor.handlers.authenticate,
          },
        }, Client)
        editor.clients [client] = true
        while editor.running and client.websocket.state == "OPEN" do
          editor:dispatch (client)
        end
        editor.clients [client] = nil
        print "<- client"
        ws:close ()
      end,
    },
  }
  Copas.addserver = copas_addserver
  editor.tasks.answer = Copas.addthread (function ()
    while editor.running do
      editor:answer ()
    end
  end)
  editor.tasks.stop = Copas.addthread (function ()
    while editor.running do
      if  next (editor.clients) == nil
      and #editor.queue == 0
      and editor.last + editor.timeout <= os.time ()
      then
        editor:stop ()
      else
        Copas.sleep (editor.timeout / 2 + 1)
      end
    end
  end)
  return true
end

function Editor.stop (editor)
  assert (getmetatable (editor) == Editor)
  if editor.running then
    editor.running = false
    if  not editor.nopush
    and editor.permissions.push then
      editor:push ()
    end
    editor.server:close ()
    for _, task in pairs (editor.tasks) do
      Copas.wakeup (task)
    end
  end
  return true
end

function Editor.pull (editor, branch)
  assert (getmetatable (editor) == Editor)
  if type (editor.repositories [branch.full_name]) == "table"
  or editor.repositories [branch.full_name] == false then
    return editor.repositories [branch.full_name]
  end
  local repository, status = Http {
    url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>", branch),
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. tostring (editor.token),
      ["User-Agent"   ] = editor.application,
    },
  }
  if status ~= 200 then
    return nil, "unable to obtain repository information: " .. tostring (status)
  end
  local url    = Url.parse (repository.clone_url)
  url.user     = editor.token
  url.password = "x-oauth-basic"
  repository.path = os.tmpname ()
  if not os.execute (Et.render ([[
    rm -rf "<%- directory %>" && \
    git clone --quiet \
              --depth=1 \
              --single-branch \
              --branch="<%- branch %>" \
              "<%- url %>" \
              "<%- directory %>"
  ]], {
    url       = Url.build (url),
    directory = repository.path,
    branch    = branch.branch,
  })) then
    return nil, "unable to pull repository: " .. tostring (status)
  end
  repository.modules = {}
  editor.repositories [branch.full_name] = repository
  return repository
end

function Editor.push (editor)
  assert (getmetatable (editor) == Editor)
  local repository = editor.repositories [editor.branch.full_name]
  if type (repository) ~= "table" then
    return true
  end
  local url    = Url.parse (repository.clone_url)
  url.user     = editor.token
  url.password = "x-oauth-basic"
  if not os.execute (Et.render ([[
    cd "<%- directory %>" && \
    git push --quiet \
             "<%- url %>"
  ]], {
    url       = Url.build (url),
    directory = repository.path,
  })) then
    return nil, "unable to push repository"
  end
  return true
end

function Editor.dispatch (editor, client)
  assert (getmetatable (editor) == Editor)
  assert (getmetatable (client) == Client)
  local ok
  local message = client.websocket:receive ()
  if not message then
    client.websocket:close ()
    return
  end
  editor.last = os.time ()
  ok, message = pcall (Json.decode, message)
  if not ok then
    return client.websocket:send (Json.encode {
      type    = "answer",
      success = false,
      reason  = "invalid JSON",
    })
  elseif type (message) ~= "table" then
    return client.websocket:send (Json.encode {
      type    = "answer",
      success = false,
      reason  = "invalid message",
    })
  elseif not message.id or not message.type then
    return client.websocket:send (Json.encode {
      id      = message.id,
      type    = "answer",
      success = false,
      reason  = "invalid message",
    })
  elseif message.type == "ping" then
    return client.websocket:send (Json.encode {
      id   = message.id,
      type = "pong",
    })
  elseif message.type == "pong" then
    return
  end
  message.client = client
  editor.queue [#editor.queue+1] = message
  Copas.wakeup (editor.tasks.answer)
end

function Editor.answer (editor)
  assert (getmetatable (editor) == Editor)
  local message = editor.queue [1]
  if not message then
    return Copas.sleep (-math.huge)
  end
  editor.last = os.time ()
  table.remove (editor.queue, 1)
  local handler = message.client.handlers [message.type]
  if not handler then
    message.client.websocket:send (Json.encode {
      id      = message.id,
      type    = "answer",
      success = false,
      reason  = "unknown type",
    })
  end
  local result, err = handler (editor, message)
  message.client.websocket:send (Json.encode {
    id      = message.id,
    type    = "answer",
    success = not not result,
    answer  = result,
    error   = err,
  })
end

function Editor.require (editor, x)
  assert (getmetatable (editor) == Editor)
  local req = Patterns.require:match (x)
  if not req then
    return nil, "invalid module"
  end
  local repository = editor.repositories [req.full_name]
                  or editor:pull (req)
  if type (repository.modules [req.module]) == "table" then
    return repository.modules [req.module]
  elseif repository.modules [req.module] == false then
    return nil, "deleted module"
  end
  -- get module within pulled data
  local filename = package.searchpath (req.module, Et.render ("<%- path %>/src/?.lua", {
    path = repository.path,
  }))
  if not filename then
    return nil, "missing module"
  end
  local file = io.open (filename, "r")
  if not file then
    return nil, "missing module"
  end
  local code = file:read "*a"
  file:close ()
  local loaded, err_loaded = _G.load (code, x, "t", Sandbox)
  if not loaded then
    return nil, "invalid layer: " .. tostring (err_loaded)
  end
  local ok, chunk = pcall (loaded)
  if not ok then
    return nil, "invalid layer: " .. tostring (chunk)
  end
  local layer, ref = Data.new {
    name = x,
  }
  local oldcurrent = editor.current
  editor.current = req.full_name
  local ok_apply, err_apply = pcall (chunk, editor.Data, layer, ref)
  if not ok_apply then
    return nil, "invalid layer: " .. tostring (err_apply)
  end
  editor.current = oldcurrent
  Data.write_to (layer, false) -- read-only
  repository.modules [req.module] = {
    layer = layer,
    ref   = ref,
    code  = code,
  }
  return repository.modules [req.module]
end

Editor.handlers = {}

function Editor.handlers.authenticate (editor, message)
  assert (getmetatable (editor) == Editor)
  local info
  local url = Url.build {
    scheme = editor.ardoises_url.scheme,
    host   = editor.ardoises_url.host,
    port   = editor.ardoises_url.port,
    path   = "/check-token",
  }
  local status
  info, status = Http {
    url     = url,
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/json",
      ["Authorization"] = "token " .. tostring (message.token),
      ["User-Agent"   ] = editor.application,
    },
  }
  if status ~= 200 then
    return nil, "authentication failure: " .. tostring (status)
  end
  if not info.repository.permissions.pull then
    message.client.handlers.authenticate = nil
    return nil, "pull permission denied"
  end
  message.client.user                  = info.user
  message.client.permissions           = info.repository.permissions
  message.client.handlers.authenticate = nil
  message.client.handlers.patch        = Editor.handlers.patch
  message.client.handlers.require      = Editor.handlers.require
  message.client.handlers.list         = Editor.handlers.list
  message.client.handlers.create       = Editor.handlers.create
  message.client.handlers.delete       = Editor.handlers.delete
  message.client.handlers.patch        = Editor.handlers.patch
  return info.repository.permissions
end

function Editor.handlers.require (editor, message)
  assert (getmetatable (editor) == Editor)
  local result, err = editor:require (message.module)
  if not result then
    return nil, err
  end
  return { code = result.code }
end

function Editor.handlers.list (editor)
  assert (getmetatable (editor) == Editor)
  local result     = {}
  local repository = editor.repositories [editor.branch.full_name]
  for module, x in pairs (repository.modules) do
    if x ~= false then
      result [module] = module .. "@" .. editor.branch.full_name
    end
  end
  return result
end

function Editor.handlers.create (editor, message)
  assert (getmetatable (editor) == Editor)
  if not message.client.permissions.push then
    return nil, "forbidden"
  end
  local req = Patterns.require:match (message.module)
  if not req then
    return nil, "invalid module"
  end
  if req.full_name ~= editor.branch.full_name then
    return nil, "invalid repository"
  end
  local repository = editor.repositories [editor.branch.full_name]
  if repository.modules [req.module] then
    return nil, "existing module"
  end
  local parts = {}
  for part in req.module:gmatch "[^%.]+" do
    parts [#parts+1] = part
  end
  local filename   = repository.path .. "/src/" .. table.concat (parts, "/") .. ".lua"
  parts [#parts]   = nil
  local directory  = repository.path .. "/src/" .. table.concat (parts, "/")
  if not os.execute (Et.render ([[
    mkdir -p "<%- directory %>"
  ]], {
    directory = directory,
  })) then
    return nil, "directory creation failure"
  end
  local file = io.open (filename, "w")
  if not file then
    return nil, "module creation failure"
  end
  file:write (tostring (message.code))
  file:close ()
  if not os.execute (Et.render ([[
    cd <%- path %> && \
    git add    <%- filename %> && \
    git commit --quiet \
               --author="<%- name %> <<%- email %>>" \
               --message="Create module '<%- module %>'."
  ]], {
    path     = repository.path,
    module   = req.module,
    filename = filename,
    name     = message.client.user.name,
    email    = message.client.user.email,
  })) then
    return nil, "commit failure"
  end
  repository.modules [req.module] = true
  for client in pairs (editor.clients) do
    if client ~= message.client then
      client.websocket:send (Json.encode {
        type   = "create",
        module = message.module,
      })
    end
  end
  return true
end

function Editor.handlers.delete (editor, message)
  assert (getmetatable (editor) == Editor)
  if not message.client.permissions.push then
    return nil, "forbidden"
  end
  local req = Patterns.require:match (message.module)
  if not req then
    return nil, "invalid module"
  end
  if req.full_name ~= editor.branch.full_name then
    return nil, "invalid repository"
  end
  local repository = editor.repositories [editor.branch.full_name]
  if not repository.modules [req.module] then
    return nil, "unknown module"
  end
  local parts  = {}
  for part in req.module:gmatch "[^%.]+" do
    parts [#parts+1] = part
  end
  local filename = "src/" .. table.concat (parts, "/") .. ".lua"
  assert (os.execute (Et.render ([[
    cd <%- path %> && \
    git rm     --quiet \
               <%- filename %> && \
    git commit --quiet \
               --author="<%- name %> <<%- email %>>" \
               --message="Delete module '<%- module %>'."
  ]], {
    path     = repository.path,
    module   = req.module,
    filename = filename,
    name     = message.client.user.name,
    email    = message.client.user.email,
  })))
  repository.modules [req.module] = false
  for client in pairs (editor.clients) do
    if client ~= message.client then
      client.websocket:send (Json.encode {
        type   = "delete",
        module = message.module,
      })
    end
  end
  return true
end

function Editor.handlers.patch (editor, message)
  assert (getmetatable (editor) == Editor)
  if not message.client.permissions.push then
    return nil, "forbidden"
  end
  -- check if module is handled locally:
  local req = Patterns.require:match (message.module)
  if req.full_name ~= editor.branch.full_name then
    return nil, "invalid module"
  end
  -- load module:
  local module, err = editor:require (message.module)
  if not module then
    return nil, err
  end
  -- check if patch is a string:
  if type (message.code) ~= "string" then
    return nil, "patch code is not a string"
  end
  local chunk, err_chunk = _G.load (message.code, message.module, "t", Sandbox)
  if not chunk then
    return nil, "invalid layer: " .. tostring (err_chunk)
  end
  local ok_loaded, loaded = pcall (chunk)
  if not ok_loaded then
    return nil, "invalid layer: " .. tostring (loaded)
  end
  -- test:
  local proxy = Data.new {
    above = module.layer,
  }
  local ok_apply, err_apply = pcall (loaded, editor.Data, proxy, module.ref)
  if not ok_apply then
    return nil, "invalid layer: " .. tostring (err_apply)
  end
  -- apply really:
  assert (pcall (loaded, editor.Data, module.layer, module.ref))
  -- commit
  local repository   = editor.repositories [editor.branch.full_name]
  local patches_file = io.open (repository.path .. "/.ardoises-patches.md", "w")
  patches_file:write (Et.render ([[
# Patch from <%- name %> <<%- email %>> at <%- date %>

]], {
    name  = message.client.user.name,
    email = message.client.user.email,
    date  = os.date ("%c", os.time ())
  }))
  local parts = {}
  for part in req.module:gmatch "[^%.]+" do
    parts [#parts+1] = part
  end
  module.code    = Data.dump (module.layer)
  local filename = "src/" .. table.concat (parts, "/") .. ".lua"
  local file = io.open (repository.path .. "/" .. filename, "w")
  file:write (module.code .. "\n")
  file:close ()
  patches_file:write (Et.render ([[
## Update of <%- module %>

```lua
<%- code %>
```

]], {
    module = message.module,
    code   = message.code,
  }))
  assert (os.execute (Et.render ([[
    cd <%- path %> && \
    git add <%- filename %>
  ]], {
    path     = repository.path,
    filename = filename,
  })))
  patches_file:close ()
  os.execute (Et.render ([[
    cd <%- path %> && \
    git add .ardoises-patches.md && \
    git commit --quiet \
               --author="<%- name %> <<%- email %>>" \
               --message="Update from the Ardoises Editor"
  ]], {
    path    = repository.path,
    name    = message.client.user.name,
    email   = message.client.user.email,
  }))
  -- send to other clients
  for client in pairs (editor.clients) do
    if client ~= message.client then
      client.websocket:send (Json.encode {
        type   = "patch",
        module = message.module,
        code   = message.code,
      })
    end
  end
  return true
end

return Editor
