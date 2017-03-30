local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Config   = require "ardoises.server.config"
local Cookie   = require "resty.cookie"
local Gettime  = require "socket".gettime
local Http     = require "ardoises.jsonhttp.resty-redis"
local Hmac     = require "openssl.hmac"
local Json     = require "rapidjson"
local Jwt      = require "resty.jwt"
local Lpeg     = require "lpeg"
local Lustache = require "lustache"
local Redis    = require "resty.redis"
local Url      = require "net.url"

local Patterns = {}

Lpeg.locale (Patterns)

Patterns.authorization =
    Lpeg.P"token"
  * Lpeg.S"\r\n\f\t "^1
  * ((Patterns.alnum + Lpeg.S "-_.")^1 / tostring)

-- http://25thandclement.com/~william/projects/luaossl.pdf
local function tohex (b)
  local x = ""
  for i = 1, #b do
    x = x .. string.format ("%.2x", string.byte (b, i))
  end
  return x
end

local function wrap (f)
  return function ()
    local redis = Redis:new ()
    if not redis:connect (Config.redis.host, Config.redis.port) then
      return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    local ok, result = xpcall (function ()
      return f {
        redis = redis,
      }
    end, function (err)
      print (tostring (err))
      print (debug.traceback ())
    end)
    redis:close ()
    if not ok then
      return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
    elseif not result then
      return
    elseif result.redirect then
      return ngx.redirect (result.redirect)
    else
      return ngx.exit (result.status)
    end
  end
end

local Server = {}

function Server.template (what, data)
  data = data or {}
  setmetatable (data, {
    __index = function (_, key)
      local file = io.open ("/static/" .. key .. ".template", "r")
      if not file then
        return nil
      end
      local template = assert (file:read "*a")
      assert (file:close ())
      return template
    end,
  })
  local file     = assert (io.open ("/static/" .. what .. ".template", "r"))
  local template = assert (file:read "*a")
  assert (file:close ())
  repeat
    local previous = template
    template = Lustache:render (template, data)
  until previous == template
  return template
end

local function register ()
  local query = ngx.req.get_uri_args ()
  if query.code and query.state then
    _G.ngx.header ["Content-type"] = "text/html"
    ngx.say (Server.template ("index", {
      server = Url.build (Config.ardoises),
      code   = "{{{register}}}",
      query  = Json.encode (query),
    }))
    ngx.exit (ngx.HTTP_OK)
  end
  return true
end

Server.register = wrap (function (context)
  local query = ngx.req.get_uri_args ()
  if not query.code and not query.state then
    return { status = ngx.HTTP_BAD_REQUEST }
  end
  local token = Jwt:verify (Config.application.secret, query.state)
  if not token
  or not token.payload
  or not token.payload.csrf then
    return { status = ngx.HTTP_UNAUTHORIZED }
  end
  local lock = Config.patterns.lock "register"
  while true do
    if context.redis:setnx (lock, "locked") == 1 then
      context.redis:expire (lock, Config.locks.timeout)
      break
    end
    ngx.sleep (0.1)
  end
  local user, result, status
  result, status = Http {
    cache   = true,
    url     = "https://github.com/login/oauth/access_token",
    method  = "POST",
    headers = {
      ["Accept"    ] = "application/json",
      ["User-Agent"] = "Ardoises",
    },
    body    = {
      client_id     = Config.application.id,
      client_secret = Config.application.secret,
      state         = query.state,
      code          = query.code,
    },
  }
  context.redis:del (Config.patterns.lock "register")
  if status ~= ngx.HTTP_OK or not result.access_token then
    return { status = ngx.HTTP_INTERNAL_SERVER_ERROR }
  end
  user, status = Http {
    url     = "https://api.github.com/user",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. result.access_token,
      ["User-Agent"   ] = "Ardoises",
    },
  }
  if status ~= ngx.HTTP_OK then
    return { status = ngx.HTTP_INTERNAL_SERVER_ERROR }
  end
  local key = Config.patterns.user (user)
  user.tokens = {
    github   = result.access_token,
    ardoises = Jwt:sign (Config.application.secret, {
      header  = {
        typ = "JWT",
        alg = "HS256",
      },
      payload = {
        login = user.login,
      },
    }),
  }
  context.redis:set (key, Json.encode (user))
  local cookie = Cookie:new ()
  cookie:set {
    expires  = nil,
    httponly = true,
    secure   = false,
    samesite = "Strict",
    key      = "Ardoises-Token",
    value    = user.tokens.ardoises,
  }
  ngx.say (Json.encode {
    user = user,
  })
  return { status = ngx.HTTP_OK }
end)

function Server.authenticate (context, options)
  local ok, err = register (context)
  if not ok then
    return nil, err
  end
  local user
  user, err = (function ()
    local headers = ngx.req.get_headers ()
    local cookie  = Cookie:new ()
    local field   = cookie:get "Ardoises-Token"
    local header  = field
                and "token " .. field
                 or headers ["Authorization"]
    if not header then
      return nil, ngx.HTTP_UNAUTHORIZED
    end
    local token = Patterns.authorization:match (header)
    if not token then
      return nil, ngx.HTTP_UNAUTHORIZED
    end
    local jwt = Jwt:verify (Config.application.secret, token)
    if not jwt then
      return nil, ngx.HTTP_UNAUTHORIZED
    end
    local info = context.redis:get (Config.patterns.user (jwt.payload))
    if info == ngx.null or not info then
      return nil, ngx.HTTP_INTERNAL_SERVER_ERROR
    end
    info = Json.decode (info)
    if not info then
      return nil, ngx.HTTP_INTERNAL_SERVER_ERROR
    end
    return info
  end) ()
  if not user and not (options or {}).optional then
    local url = Url.parse (Url.build (Config.ardoises))
    url.path               = "/login"
    url.query.redirect_uri = ngx.var.request_uri
    context.redis:close ()
    return ngx.redirect (Url.build (url))
  end
  return user, err
end

Server.root = wrap (function (context)
  local user = Server.authenticate (context, {
    optional = true,
  })
  if user then
    return { redirect = "/dashboard" }
  else
    return { redirect = "/overview" }
  end
end)

Server.dashboard = wrap (function (context)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    server  = Url.build (Config.ardoises),
    user    = user,
    code    = "{{{dashboard-code}}}",
  }))
  return { status = ngx.HTTP_OK }
end)

Server.overview = wrap (function (context)
  local user = Server.authenticate (context, {
    optional = true,
  })
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    server  = Url.build (Config.ardoises),
    user    = user,
    content = "{{{overview}}}"
  }))
  return { status = ngx.HTTP_OK }
end)

Server.legal = wrap (function ()
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    server  = Url.build (Config.ardoises),
    content = "{{{legal}}}"
  }))
  return { status = ngx.HTTP_OK }
end)

Server.view = wrap (function (context)
print (1)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
print (2)
  -- check collaborator:
  local ckey = Config.patterns.collaborator ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, user)
  local collaboration = context.redis:get (ckey)
print (tostring (collaboration))
  if collaboration == ngx.null or not collaboration then
    return { status = ngx.HTTP_FORBIDDEN }
  end
  collaboration = assert (Json.decode (collaboration))
  -- get repository:
  local repository = context.redis:get (Config.patterns.repository (collaboration.repository))
  if repository == ngx.null or not repository then
    return { status = ngx.HTTP_FORBIDDEN }
  end
  repository = assert (Json.decode (repository))
  -- answer:
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    server     = Url.build (Config.ardoises),
    user       = user,
    repository = repository,
    branch     = ngx.var.branch,
    code       = "{{{editor-code}}}",
  }))
  return { status = ngx.HTTP_OK }
end)

Server.login = wrap (function ()
  local query            = ngx.req.get_uri_args ()
  local url              = Url.parse "https://github.com/login/oauth/authorize"
  local redirect         = Url.parse (Url.build (Config.ardoises))
  redirect.path          = query.redirect_uri or "/"
  url.query.redirect_uri = Url.build (redirect)
  url.query.client_id    = Config.application.id
  url.query.scope        = "user:email admin:repo_hook"
  url.query.state        = Jwt:sign (Config.application.secret, {
    header  = {
      typ = "JWT",
      alg = "HS256",
    },
    payload = {
      csrf = true,
    },
  })
  return { redirect  = Url.build (url) }
end)

Server.logout = wrap (function ()
  local cookie = Cookie:new ()
  cookie:set {
    key      = "Ardoises-Token",
    value    = "deleted",
    expires  = "Thu, 01 Jan 1970 00:00:00 GMT",
    httponly = true,
    secure   = false,
    samesite = "Strict",
  }
  return { redirect = "/" }
end)

Server.my_user = wrap (function (context)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
  ngx.say (Json.encode {
    login      = user.login,
    name       = user.name,
    company    = user.company,
    location   = user.location,
    bio        = user.bio,
    avatar_url = user.avatar_url,
  })
  return { status = ngx.HTTP_OK }
end)

Server.my_ardoises = wrap (function (context)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
  local result = {}
  -- find collaborators in database:
  local cursor = 0
  repeat
    local res = context.redis:scan (cursor,
      "match", Config.patterns.collaborator ({
        owner = { login = "*" },
        name  = "*",
      }, user),
      "count", 100)
    if res == ngx.null or not res then
      break
    end
    cursor = res [1]
    local keys = res [2]
    for _, key in ipairs (keys) do
      local entry = context.redis:get (key)
      if entry ~= ngx.null and entry then
        entry = Json.decode (entry)
        local repository = context.redis:get (Config.patterns.repository (entry.repository))
        entry.repository = Json.decode (repository)
        result [#result+1] = entry
      end
    end
  until cursor == "0"
  ngx.say (Json.encode (result))
  return { status = ngx.HTTP_OK }
end)

Server.editor = wrap (function (context)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
  -- check collaborator:
  local ckey = Config.patterns.collaborator ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, user)
  local collaboration = context.redis:get (ckey)
  if collaboration == ngx.null or not collaboration then
    return { status = ngx.HTTP_FORBIDDEN }
  end
  collaboration = assert (Json.decode (collaboration))
  -- get repository:
  local repository = context.redis:get (Config.patterns.repository (collaboration.repository))
  if repository == ngx.null or not repository then
    return { status = ngx.HTTP_FORBIDDEN }
  end
  repository = assert (Json.decode (repository))
  -- get editor:
  local lock = Config.patterns.lock (Lustache:render ("editor:{{{owner}}}/{{{name}}}/{{{branch}}}", ngx.var))
  while true do
    if context.redis:setnx (lock, "locked") == 1 then
      context.redis:expire (lock, Config.locks.timeout)
      break
    end
    ngx.sleep (0.1)
  end
  local key = Config.patterns.editor ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, ngx.var.branch)
  local editor = context.redis:get (key)
  if editor == ngx.null or not editor then
    local info, status = Http {
      url    = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}/json", {
        host = Config.docker.host,
        port = Config.docker.port,
        id   = Config.docker_id,
      }),
      method = "GET",
    }
    assert (status == ngx.HTTP_OK, status)
    Http {
      url    = Lustache:render ("http://{{{host}}}:{{{port}}}/images/create", {
        host = Config.docker.host,
        port = Config.docker.port,
      }),
      method = "POST",
      query  = {
        fromImage = Config.image,
        tag       = "latest",
      },
      timeout = 120,
    }
    local service
    service, status = Http {
      url     = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/create", {
        host = Config.docker.host,
        port = Config.docker.port,
      }),
      method  = "POST",
      timeout = 120,
      body    = {
        Entrypoint   = "ardoises-editor",
        Cmd          = {
          Lustache:render ("{{{owner}}}/{{{name}}}:{{{branch}}}", ngx.var),
          Config.application.token,
        },
        Image        = Config.image,
        ExposedPorts = {
          ["8080/tcp"] = {},
        },
        HostConfig   = {
          PublishAllPorts = false,
          NetworkMode     = info.HostConfig.NetworkMode,
        },
      },
    }
    assert (status == ngx.HTTP_CREATED, status)
    local created_at = Gettime ()
    local _
    _, status = Http {
      method  = "POST",
      timeout = 120,
      url     = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}/start", {
        host = Config.docker.host,
        port = Config.docker.port,
        id   = service.Id,
      }),
    }
    assert (status == ngx.HTTP_NO_CONTENT, status)
    local start = Gettime ()
    local docker_url = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}", {
      host = Config.docker.host,
      port = Config.docker.port,
      id   = service.Id,
    })
    context.redis:set (key, Json.encode {
      repository = collaboration.repository,
      docker_id  = service.Id,
      created_at = created_at,
    })
    while Gettime () - start <= 120 do
      info, status = Http {
        method = "GET",
        url    = docker_url .. "/json",
      }
      assert (status == ngx.HTTP_OK, status)
      if info.State.Running then
        local _, network = next (info.NetworkSettings.Networks)
        context.redis:set (key, Json.encode {
          repository = collaboration.repository,
          docker_id  = service.Id,
          created_at = created_at,
          started_at = Gettime (),
          target_url = Lustache:render ("http://{{{host}}}:8080", {
            host = network.IPAddress,
          }),
          editor_url = Url.build {
            scheme = "wss",
            host   = Config.ardoises.host,
            port   = Config.ardoises.port,
            path   = Lustache:render ("/websockets/{{{owner}}}/{{{name}}}/{{{branch}}}", {
              owner  = ngx.var.owner,
              name   = ngx.var.name,
              branch = ngx.var.branch,
            }),
          },
        })
        break
      elseif info.State.Dead then
        assert (false)
      else
        _G.ngx.sleep (1)
      end
    end
  end
  context.redis:del (lock)
  editor = context.redis:get (key)
  if editor == ngx.null or not editor then
    return { status = ngx.HTTP_NOT_FOUND }
  end
  editor = assert (Json.decode (editor))
  if not editor.target_url or not editor.editor_url then
    return { status = ngx.HTTP_NOT_FOUND }
  end
  ngx.say (Json.encode {
    user        = user,
    permissions = collaboration.collaborator.permissions,
    repository  = repository,
    branch      = ngx.var.branch,
    editor_url  = editor.editor_url,
  })
  return { status = ngx.HTTP_OK }
end)

Server.websocket = wrap (function (context)
  local key = Config.patterns.editor ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, ngx.var.branch)
  local editor = context.redis:get (key)
  if editor == ngx.null or not editor then
    return { status = ngx.HTTP_NOT_FOUND }
  end
  editor = assert (Json.decode (editor))
  if not editor.target_url then
    return { status = ngx.HTTP_NOT_FOUND }
  end
  _G.ngx.var.target = editor.target_url
end)

Server.webhook = wrap (function (context)
  ngx.req.read_body ()
  local data    = ngx.req.get_body_data ()
  local headers = ngx.req.get_headers ()
  local hmac    = Hmac.new (Config.application.secret)
  if not data then
    return { status = ngx.HTTP_BAD_REQUEST }
  end
  if "sha1=" .. tohex (hmac:final (data)) ~= headers ["X-Hub-Signature"] then
    return { status = ngx.HTTP_BAD_REQUEST }
  end
  data = assert (Json.decode (data))
  local repository = data.repository
  if not repository then
    return { status = ngx.HTTP_OK }
  end
  local lock = Config.patterns.lock (repository.full_name)
  while true do
    if context.redis:setnx (lock, "locked") == 1 then
      context.redis:expire (lock, Config.locks.timeout)
      break
    end
    ngx.sleep (0.1)
  end
  -- delete collaborators in database:
  local cursor = 0
  repeat
    local res = context.redis:scan (cursor,
      "match", Config.patterns.collaborator (repository, { login = "*" }),
      "count", 100)
    if res == ngx.null or not res then
      break
    end
    cursor = res [1]
    local keys = res [2]
    for _, key in ipairs (keys) do
      context.redis:del (key)
    end
  until cursor == "0"
  -- update data:
  local collaborators, status = Http {
    url     = repository.collaborators_url:gsub ("{/collaborator}", ""),
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.korra-preview+json",
      ["Authorization"] = "token " .. Config.application.token,
      ["User-Agent"   ] = "Ardoises",
    },
  }
  if status >= 400 and status < 500 then
    -- delete repository:
    context.redis:del (Config.patterns.repository (repository))
    -- delete webhook(s):
    (function ()
      local user = context.redis:get (Config.patterns.user (repository.owner))
      if user == ngx.null or not user then
        return
      end
      user = Json.decode (user)
      if not user then
        return
      end
      local webhooks, wh_status = Http {
        url     = repository.hooks_url,
        method  = "GET",
        headers = {
          ["Accept"       ] = "application/vnd.github.v3+json",
          ["Authorization"] = "token " .. user.tokens.github,
          ["User-Agent"   ] = "Ardoises",
        },
      }
      if wh_status ~= 200 then
        return
      end
      for _, hook in ipairs (webhooks) do
        if hook.config.url:find (Config.ardoises.url, 1, true) then
          Http {
            url     = hook.url,
            method  = "DELETE",
            headers = {
              ["Accept"       ] = "application/vnd.github.v3+json",
              ["Authorization"] = "token " .. user.tokens.github,
              ["User-Agent"   ] = "Ardoises",
            },
          }
        end
      end
    end) ()
  elseif status == 200 then
    -- get branches:
    local branches
    branches, status = Http {
      url     = repository.branches_url:gsub ("{/branch}", ""),
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.loki-preview+json",
        ["Authorization"] = "token " .. Config.application.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    assert (status == ngx.HTTP_OK, status)
    repository.branches = branches
    -- update repository:
    context.redis:set (Config.patterns.repository (repository), Json.encode (repository))
    -- update collaborators:
    for _, collaborator in ipairs (collaborators) do
      local key = Config.patterns.collaborator (repository, collaborator)
      context.redis:set (key, Json.encode {
        repository   = {
          owner = { login = repository.owner.login },
          name  = repository.name,
        },
        collaborator = collaborator,
      })
    end
  end
  context.redis:del (Config.patterns.lock (repository.full_name))
  return { status = ngx.HTTP_OK }
end)

return Server
