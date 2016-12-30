local Colors    = require "ansicolors"
local Copas     = require "copas"
local Et        = require "etlua"
local Http      = require "ardoises.jsonhttp".copas
local Json      = require "cjson"
local Layer     = require "layeredata"
local Patterns  = require "ardoises.patterns"
local Url       = require "socket.url"
local Websocket = require "websocket"

-- Messages:
-- { id = ..., type = "authenticate", token = "..." }
-- { id = ..., type = "patch"       , patches = { module = ..., code = ... } }
-- { id = ..., type = "require"     , module = "..." }
-- { id = ..., type = "list"        }
-- { id = ..., type = "create"      , module = "..." }
-- { id = ..., type = "delete"      , module = "..." }
-- { id = ..., type = "answer"      , success = true|false, reason = "..." }
-- { id = ..., type = "execute"     }

local Editor = {}
Editor.__index = Editor

function Editor.create (options)
  local repository = assert (Patterns.repository:match (options.repository))
  assert (repository.branch)
  local editor     = setmetatable ({
    repository   = assert (repository.full),
    tokens       = {
      pull = assert (options.token),
      push = nil,
    },
    timeout      = assert (options.timeout),
    port         = assert (options.port),
    application  = assert (options.application),
    clients      = setmetatable ({}, { __mode = "k" }),
    running      = false,
    last         = false,
    tasks        = {},
    queue        = {},
    repositories = {}, -- repository -> module -> layer
    Layer        = setmetatable ({}, { __index = Layer }),
  }, Editor)
  editor.Layer.require = function (name)
    if not Patterns.require:match (name) then
      name = name .. "@" .. editor.current
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
  local repository = editor:pull (editor.repository)
  if repository then
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
  end
  local copas_addserver = Copas.addserver
  local addserver       = function (socket, f)
    editor.socket = socket
    editor.host, editor.port = socket:getsockname ()
    copas_addserver (socket, f)
    print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} Start editor at %{green}<%- url %>%{reset}.", {
      time = os.date "%c",
      url  = "ws://" .. editor.host .. ":" .. tostring (editor.port),
    })))
    editor.last    = os.time ()
    editor.running = true
  end
  Copas.addserver = addserver
  editor.server   = Websocket.server.copas.listen {
    port      = editor.port,
    default   = function () end,
    protocols = {
      ardoises = function (ws)
        print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} New connection.", {
          time = os.date "%c",
        })))
        editor.last  = os.time ()
        local client = {
          ws          = ws,
          token       = nil,
          permissions = {
            read  = nil,
            write = nil,
          },
          handlers    = {
            authenticate = Editor.handlers.authenticate,
          },
        }
        editor.clients [client] = true
        while editor.running and ws.state == "OPEN" do
          editor:dispatch (client)
        end
        editor.clients [client] = nil
        ws:close ()
      end,
    },
  }
  Copas.addserver = copas_addserver
  editor.tasks.answer = Copas.addthread (function ()
    while editor.running do
      editor:answer ()
      if #editor.queue == 0 then
        Copas.sleep (-math.huge)
      end
    end
  end)
  editor.tasks.stop = Copas.addthread (function ()
    while editor.running do
      if  next (editor.clients) == nil
      and #editor.queue == 0
      and editor.last + editor.timeout < os.time ()
      then
        editor:stop ()
      else
        Copas.sleep (editor.timeout / 2)
      end
    end
  end)
end

function Editor.stop (editor, options)
  assert (getmetatable (editor) == Editor)
  options = options or {}
  print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} Stop editor.", {
    time = os.date "%c",
  })))
  editor.running = false
  Copas.addthread (function ()
    if not options.nopush then
      editor:push (editor.repository)
    end
    editor.server:close ()
    for _, task in pairs (editor.tasks) do
      Copas.wakeup (task)
    end
  end)
end

function Editor.pull (editor, name)
  assert (getmetatable (editor) == Editor)
  if editor.repositories [name] then
    return editor.repositories [name]
  end
  local repo = Patterns.repository:match (name)
  if not repo then
    return nil, "invalid name"
  end
  local repository, status = Http {
    url     = Et.render ("https://api.github.com/repos/<%- repository %>", {
      repository = repo.repository,
    }),
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. editor.tokens.pull,
      ["User-Agent"   ] = editor.application,
    },
  }
  if status ~= 200 then
    return nil, status
  end
  local url    = Url.parse (repository.clone_url)
  url.user     = editor.tokens.pull
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
    branch    = repo.branch or repository.default_branch,
  })) then
    print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} %{red}Cannot pull <%- repository %>%{reset}.", {
      time       = os.date "%c",
      repository = name,
    })))
    return nil, status
  end
  repository.modules = {}
  editor.repositories [name] = repository
  return repository
end

function Editor.push (editor, name)
  assert (getmetatable (editor) == Editor)
  assert (name == editor.repository)
  local repository = editor.repositories [name]
  if not repository then
    return
  end
  local url        = Url.parse (repository.clone_url)
  url.user         = editor.tokens.push
  url.password     = "x-oauth-basic"
  if not os.execute (Et.render ([[
    cd "<%- directory %>" && \
    git push --quiet \
             "<%- url %>"
  ]], {
    url       = Url.build (url),
    directory = repository.path,
  })) then
    print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} %{red}Cannot push <%- repository %>%{reset}.", {
      time       = os.date "%c",
      repository = name,
    })))
  end
  return true
end

function Editor.dispatch (editor, client)
  assert (getmetatable (editor) == Editor)
  local ok
  local message = client.ws:receive ()
  if not message then
    client.ws:close ()
    return
  end
  editor.last = os.time ()
  ok, message = pcall (Json.decode, message)
  if not ok then
    client.ws:send (Json.encode {
      type    = "answer",
      success = false,
      reason  = "invalid JSON",
    })
  elseif type (message) ~= "table" then
    client.ws:send (Json.encode {
      type    = "answer",
      success = false,
      reason  = "invalid message",
    })
  elseif not message.id or not message.type then
    client.ws:send (Json.encode {
      id      = message.id,
      type    = "answer",
      success = false,
      reason  = "invalid message",
    })
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
    message.client.ws:send (Json.encode {
      id      = message.id,
      type    = "answer",
      success = false,
      reason  = "unknown type",
    })
  end
  local ok, result = pcall (handler, editor, message)
  if ok then
    message.client.ws:send (Json.encode {
      id      = message.id,
      type    = "answer",
      success = true,
      answer  = result,
    })
  else
    message.client.ws:send (Json.encode {
      id      = message.id,
      type    = "answer",
      success = false,
      error   = result,
    })
  end
end

function Editor.require (editor, x)
  assert (getmetatable (editor) == Editor)
  local req = Patterns.require:match (x)
  if not req then
    error { reason = "invalid module" }
  end
  local repository = editor.repositories [req.full]
                  or editor:pull (req.full)
  if type (repository.modules [req.module]) == "table" then
    return repository.modules [req.module]
  elseif repository.modules [req.module] == false then
    error { reason = "deleted" }
  end
  -- get module within pulled data
  local filename = package.searchpath (req.module, Et.render ("<%- path %>/src/?.lua", {
    path = repository.path,
  }))
  if not filename then
    error { reason = "not found" }
  end
  local file = io.open (filename, "r")
  if not file then
    error { reason = "not found" }
  end
  local code = file:read "*a"
  file:close ()
  local loaded, err_loaded = _G.load (code, x, "t", _G)
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
  editor.current = req.full
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

Editor.handlers = {}

function Editor.handlers.authenticate (editor, message)
  assert (getmetatable (editor) == Editor)
  do
    local user, status = Http {
      url     = "https://api.github.com/user",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. message.token,
        ["User-Agent"   ] = editor.application,
      },
    }
    if status ~= 200 then
      error { status = status }
    end
    message.client.user  = user
    message.client.token = message.token
  end
  do
    local emails, status = Http {
      url     = "https://api.github.com/user/emails",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. message.token,
        ["User-Agent"   ] = editor.application,
      },
    }
    if status ~= 200 then
      error { status = status }
    end
    message.client.user.emails = emails
    for _, t in ipairs (emails) do
      if t.primary then
        message.client.user.email = t.email
      end
    end
  end
  do
    local repo = Patterns.repository:match (editor.repository)
    local result, status = Http {
      url     = Et.render ("https://api.github.com/repos/<%- repository %>", {
        repository = repo.repository,
      }),
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. message.token,
        ["User-Agent"   ] = editor.application,
      },
    }
    if status ~= 200 then
      error { status = status }
    end
    print (Colors (Et.render ("%{blue}[<%- time %>]%{reset} User %{green}<%- login %>%{reset} <%- pull %> and <%- push %>.", {
      time       = os.date "%c",
      login      = message.client.user.login,
      pull       = result.permissions.pull
               and "%{green}can read%{reset}"
                or "%{red}cannot read%{reset}",
      push       = result.permissions.push
               and "%{green}can write%{reset}"
                or "%{red}cannot write%{reset}",
    })))
    if not result.permissions.pull then
      message.client.handlers.authenticate = nil
      error (result)
    end
    message.client.permissions           = result.permissions
    message.client.handlers.authenticate = nil
    message.client.handlers.patch        = Editor.handlers.patch
    message.client.handlers.require      = Editor.handlers.require
    message.client.handlers.list         = Editor.handlers.list
    message.client.handlers.create       = Editor.handlers.create
    message.client.handlers.delete       = Editor.handlers.delete
    message.client.handlers.patch        = Editor.handlers.patch
    return {
      read  = result.permissions.pull,
      write = result.permissions.push,
    }
  end
end

function Editor.handlers.require (editor, message)
  assert (getmetatable (editor) == Editor)
  local result, err = editor:require (message.module)
  if result then
    return { code = result.code }
  else
    error (err)
  end
end

function Editor.handlers.list (editor)
  assert (getmetatable (editor) == Editor)
  local result = {}
  for name, repository in pairs (editor.repositories) do
    local subresult = {}
    for module, x in pairs (repository.modules) do
      if x ~= false then
        subresult [module] = module .. "@" .. name
      end
    end
    result [name] = subresult
  end
  return result
end

function Editor.handlers.create (editor, message)
  assert (getmetatable (editor) == Editor)
  if not message.client.permissions.push then
    error { reason = "forbidden" }
  end
  local req = Patterns.require:match (message.module)
  if not req then
    error { reason = "invalid module" }
  end
  if req.full ~= editor.repository then
    error { reason = "invalid repository"}
  end
  local repository = editor.repositories [editor.repository]
  if repository.modules [req.module] then
    error { reason = "existing module"}
  end
  local parts  = {}
  for part in req.module:gmatch "[^%.]+" do
    parts [#parts+1] = part
  end
  local filename   = repository.path .. "/src/" .. table.concat (parts, "/") .. ".lua"
  parts [#parts]   = nil
  local directory  = repository.path .. "/src/" .. table.concat (parts, "/")
  if not os.execute (Et.render ([[ mkdir -p "<%- directory %>" ]], {
    directory = directory,
  })) then
    error { reason = "failure" }
  end
  local file = io.open (filename, "w")
  if not file then
    error { reason = "failure" }
  end
  file:write (([[
    return function (Layer, layer, ref)
    end
  ]]):gsub ("    ", ""))
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
    assert (false)
  end
  repository.modules [req.module] = true
  for client in pairs (editor.clients) do
    if client ~= message.client then
      client:send (Json.encode {
        type   = "create",
        module = message.module,
      })
    end
  end
  editor.tokens.push = message.client.token
end

function Editor.handlers.delete (editor, message)
  assert (getmetatable (editor) == Editor)
  if not message.client.permissions.push then
    error { reason = "forbidden" }
  end
  local req = Patterns.require:match (message.module)
  if not req then
    error { reason = "invalid module" }
  end
  if req.full ~= editor.repository then
    error { reason = "invalid repository"}
  end
  local repository = editor.repositories [editor.repository]
  if not repository.modules [req.module] then
    error { reason = "unknown module"}
  end
  local parts  = {}
  for part in req.module:gmatch "[^%.]+" do
    parts [#parts+1] = part
  end
  local filename = "src/" .. table.concat (parts, "/") .. ".lua"
  if not os.execute (Et.render ([[
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
  })) then
    assert (false)
  end
  repository.modules [req.module] = false
  for client in pairs (editor.clients) do
    if client ~= message.client then
      client:send (Json.encode {
        type   = "delete",
        module = message.module,
      })
    end
  end
  editor.tokens.push = message.client.token
end

function Editor.handlers.patch (editor, message)
  assert (getmetatable (editor) == Editor)
  if not message.client.permissions.push then
    error { reason = "forbidden" }
  end
  local errors  = {}
  local modules = {}
  local function rollback ()
    for _, module in pairs (modules) do
      Layer.write_to (module.layer, nil)
      local refines = module.layer [Layer.key.refines]
      refines [Layer.len (refines)] = nil
      Layer.write_to (module.layer, false)
      module.current = nil
    end
  end
  -- load modules
  for _, patch in ipairs (message.patches) do
    local ok, err = pcall (function ()
      local module = editor:require (patch.module)
      modules [patch.module] = module
      module.current = Layer.new {
        temporary = true,
      }
      Layer.write_to (module.layer, nil)
      local refines = module.layer [Layer.key.refines]
      refines [Layer.len (refines)+1] = module.current
      Layer.write_to (module.layer, module.current)
    end)
    if not ok then
      errors [patch.module] = err
    end
  end
  if next (errors) then
    rollback ()
    error (errors)
  end
  -- apply patches
  for _, patch in ipairs (message.patches) do
    local module = modules [patch.module]
    local ok, err = pcall (function ()
      if type (patch.code) ~= "string" then
        error { reason = "patch code is not a string" }
      end
      local chunk, err_chunk = _G.load (patch.code, patch.module, "t", _G)
      if not chunk then
        error { reason = err_chunk }
      end
      local ok_loaded, loaded = pcall (chunk)
      if not ok_loaded then
        error { reason = loaded }
      end
      local ok_apply, err_apply = pcall (loaded, editor.Layer, module.layer, module.ref)
      if not ok_apply then
        error { reason = err_apply }
      end
    end)
    if not ok then
      errors [patch.module] = err
    end
  end
  if next (errors) then
    rollback ()
    error (errors)
  end
  -- commit
  local repository = editor.repositories [editor.repository]
  for _, patch in ipairs (message.patches) do
    local module = modules [patch.module]
    Layer.merge (module.current, module.remote)
    local req   = assert (Patterns.require:match (patch.module))
    local parts = {}
    for part in req.module:gmatch "[^%.]+" do
      parts [#parts+1] = part
    end
    local filename = "src/" .. table.concat (parts, "/") .. ".lua"
    local file     = io.open (repository.path .. "/" .. filename, "w")
    file:write (Layer.dump (module.remote))
    file:close ()
    if not os.execute (Et.render ([[
      cd <%- path %> && \
      git add <%- filename %>
    ]], {
      path     = repository.path,
      filename = filename,
    })) then
      assert (false)
    end
  end
  rollback ()
  local patches = {}
  for _, patch in ipairs (message.patches) do
    patches [#patches+1] = Et.render ([[
===== <%- module %> =====
<%- code %>
]], { module = patch.module,
      code   = patch.code,
    })
  end
  if not os.execute (Et.render ([[
    cd <%- path %> && \
    git commit --quiet \
               --author="<%- name %> <<%- email %>>" \
               --message=<%- message %>
  ]], {
    path    = repository.path,
    message = string.format ("%q", table.concat (patches, "\n")),
    name    = message.client.user.name,
    email   = message.client.user.email,
  })) then
    assert (false)
  end
  -- send to other clients
  for client in pairs (editor.clients) do
    if client ~= message.client then
      client:send (Json.encode {
        type    = "patch",
        patches = message.patches,
      })
    end
  end
  editor.tokens.push = message.client.token
end

return Editor
