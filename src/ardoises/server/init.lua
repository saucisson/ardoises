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
  local file, err = io.open ("/static/" .. what .. ".template", "r")
  if not file then
    print (err)
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  local template = assert (file:read "*a")
  assert (file:close ())
  repeat
    local previous = template
    template = Lustache:render (template, data)
  until previous == template
  return template
end

function Server.authenticate (noexit)
  local headers = ngx.req.get_headers ()
  local cookie  = Cookie:new ()
  local field   = cookie:get "Ardoises-Token"
  local header  = field
              and "token " .. field
               or headers ["Authorization"]
  if not header then
    return not noexit and ngx.exit (ngx.HTTP_UNAUTHORIZED) or nil
  end
  local token = Patterns.authorization:match (header)
  if not token then
    return not noexit and ngx.exit (ngx.HTTP_UNAUTHORIZED) or nil
  end
  local jwt = Jwt:verify (Config.application.secret, token)
  if not jwt then
    return not noexit and ngx.exit (ngx.HTTP_UNAUTHORIZED) or nil
  end
  local redis = Redis:new ()
  if not redis:connect (Config.redis.host, Config.redis.port) then
    return not noexit and ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR) or nil
  end
  local user = redis:get (Config.patterns.user (jwt.payload))
  redis:set_keepalive ()
  if user == ngx.null or not user then
    return not noexit and ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR) or nil
  end
  user = Json.decode (user)
  if not user then
    return not noexit and ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR) or nil
  end
  return user
end

function Server.root ()
  local user = Server.authenticate (true)
  if user then
    return ngx.redirect "/dashboard"
  else
    return ngx.redirect "/overview"
  end
end

function Server.dashboard ()
  local user = Server.authenticate ()
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    user    = user,
    content = "{{{dashboard}}}",
    code    = "{{{dashboard-code}}}",
  }))
  return ngx.exit (ngx.HTTP_OK)
end

function Server.overview ()
  local user = Server.authenticate (true)
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    user    = user,
    content = "{{{overview}}}"
  }))
  return ngx.exit (ngx.HTTP_OK)
end

function Server.login ()
  local url           = Url.parse "https://github.com/login/oauth/authorize"
  url.query.client_id = Config.application.id
  url.query.scope     = "user:email admin:repo_hook"
  url.query.state     = Jwt:sign (Config.application.secret, {
    header  = {
      typ = "JWT",
      alg = "HS256",
    },
    payload = {
      csrf = true,
    },
  })
  return ngx.redirect (tostring (url))
end

function Server.logout ()
  local cookie = Cookie:new ()
  cookie:set {
    key      = "Ardoises-Token",
    value    = "deleted",
    expires  = "Thu, 01 Jan 1970 00:00:00 GMT",
    httponly = true,
    secure   = false,
    samesite = "Strict",
  }
  return ngx.redirect "/"
end

function Server.register ()
  local query = ngx.req.get_uri_args ()
  local token = Jwt:verify (Config.application.secret, query.state)
  if not token
  or not token.payload
  or not token.payload.csrf then
    return ngx.exit (ngx.HTTP_UNAUTHORIZED)
  end
  local redis = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  while true do
    if redis:setnx (Config.patterns.lock "register", "locked") then
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
  redis:del (Config.patterns.lock "register")
  if status ~= ngx.HTTP_OK
  or not result.access_token then
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
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
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
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
  redis:set (key, Json.encode (user))
  local cookie = Cookie:new ()
  cookie:set {
    expires  = nil,
    httponly = true,
    secure   = false,
    samesite = "Strict",
    key      = "Ardoises-Token",
    value    = user.tokens.ardoises,
  }
  return ngx.redirect "/"
end

function Server.my_user ()
  local user = Server.authenticate ()
  ngx.say (Json.encode {
    login      = user.login,
    name       = user.name,
    company    = user.company,
    location   = user.location,
    bio        = user.bio,
    avatar_url = user.avatar_url,
  })
  return ngx.exit (ngx.HTTP_OK)
end

function Server.my_ardoises ()
  local user   = Server.authenticate ()
  local result = {}
  local redis  = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  -- find collaborators in database:
  local cursor = 0
  repeat
    local res = redis:scan (cursor,
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
      local entry = redis:get (key)
      if entry ~= ngx.null and entry then
        result [#result+1] = Json.decode (entry)
      end
    end
  until cursor == "0"
  ngx.say (Json.encode (result))
  return ngx.exit (ngx.HTTP_OK)
end

function Server.editor ()
  local user  = Server.authenticate ()
  local redis = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  -- check collaborator:
  local ckey = Config.patterns.collaborator ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, user)
  local collaboration = redis:get (ckey)
  if collaboration == ngx.null or not collaboration then
    return ngx.exit (ngx.HTTP_FORBIDDEN)
  end
  collaboration = Json.decode (collaboration)
  if not collaboration then
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  -- get editor:
  local lock = Config.patterns.lock (Lustache:render ("editor:{{{owner}}}/{{{name}}}/{{{branch}}}", ngx.var))
  while true do
    if redis:setnx (lock, "locked") then
      break
    end
    ngx.sleep (0.1)
  end
  local key = Config.patterns.editor ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, ngx.var.branch)
  local editor = redis:get (key)
  if editor == ngx.null or not editor then
    xpcall (function ()
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
        timeout = math.huge,
      }
      local service, status = Http {
        url    = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/create", {
          host = Config.docker.host,
          port = Config.docker.port,
        }),
        method = "POST",
        body   = {
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
            PublishAllPorts = true,
          },
        },
      }
      assert (status == 201, status)
      local created_at = Gettime ()
      local _
      _, status = Http {
        method = "POST",
        url    = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}/start", {
          host = Config.docker.host,
          port = Config.docker.port,
          id   = service.Id,
        }),
      }
      assert (status == 204, status)
      local start = Gettime ()
      local docker_url = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}", {
        host = Config.docker.host,
        port = Config.docker.port,
        id   = service.Id,
      })
      redis:set (key, Json.encode {
        repository = collaboration.repository,
        docker_id  = service.Id,
        created_at = created_at,
      })
      local info
      while Gettime () - start <= 120 do
        info, status = Http {
          method = "GET",
          url    = docker_url .. "/json",
        }
        assert (status == 200, status)
        if info.State.Running then
          local data = ((info.NetworkSettings.Ports ["8080/tcp"] or {}) [1] or {})
          if data.HostPort then
            redis:set (key, Json.encode {
              repository = collaboration.repository,
              docker_id  = service.Id,
              created_at = created_at,
              started_at = Gettime (),
              editor_url = Lustache:render ("ws://{{{host}}}:{{{port}}}", {
                host = data.HostIp,
                port = data.HostPort,
              }),
            })
            return
          end
        elseif info.State.Dead then
          assert (false)
        else
          _G.ngx.sleep (1)
        end
      end
    end, function (err)
      print (err)
      print (debug.traceback ())
    end)
  end
  redis:del (lock)
  editor = redis:get (key)
  redis:set_keepalive ()
  if editor == ngx.null or not editor then
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  editor = Json.decode (editor)
  if not editor then
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  if not editor.editor_url then
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  local headers = ngx.req.get_headers ()
  if headers ["Accept"] == "application/json" then
    ngx.say (Json.encode {
      user        = user,
      permissions = collaboration.collaborator.permissions,
      repository  = collaboration.repository,
      branch      = ngx.var.branch,
      editor_url  = editor.editor_url,
    })
  else
    _G.ngx.header ["Content-type"] = "text/html"
    ngx.say (Server.template ("index", {
      user        = user,
      permissions = collaboration.collaborator.permissions,
      repository  = collaboration.repository,
      branch      = ngx.var.branch,
      editor_url  = editor.editor_url,
      content     = "{{{editor}}}",
      code        = "{{{editor-code}}}",
    }))
  end
  return ngx.exit (ngx.HTTP_OK)
end

function Server.webhook ()
  ngx.req.read_body ()
  local data    = ngx.req.get_body_data ()
  local headers = ngx.req.get_headers ()
  local hmac    = Hmac.new (Config.application.secret)
  if not data then
    return ngx.exit (ngx.HTTP_BAD_REQUEST)
  end
  if "sha1=" .. tohex (hmac:final (data)) ~= headers ["X-Hub-Signature"] then
    return ngx.exit (ngx.HTTP_BAD_REQUEST)
  end
  data = Json.decode (data)
  if not data then
    return ngx.exit (ngx.HTTP_BAD_REQUEST)
  end
  local repository = data.repository
  if not repository then
    return ngx.exit (ngx.HTTP_OK)
  end
  local redis = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  while true do
    if redis:setnx (Config.patterns.lock (repository.full_name), "locked") then
      break
    end
    ngx.sleep (0.1)
  end
  -- delete collaborators in database:
  local cursor = 0
  repeat
    local res = redis:scan (cursor,
      "match", Config.patterns.collaborator (repository, { login = "*" }),
      "count", 100)
    if res == ngx.null or not res then
      break
    end
    cursor = res [1]
    local keys = res [2]
    for _, key in ipairs (keys) do
      redis:del (key)
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
    redis:del (Config.patterns.repository (repository))
    -- delete webhook(s):
    (function ()
      local user = redis:get (Config.patterns.user (repository.owner))
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
          ["Authorization"] = "token " .. user.token,
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
              ["Authorization"] = "token " .. user.token,
              ["User-Agent"   ] = "Ardoises",
            },
          }
        end
      end
    end) ()
  elseif status == 200 then
    -- update repository:
    redis:set (Config.patterns.repository (repository), Json.encode (repository))
    -- update collaborators:
    for _, collaborator in ipairs (collaborators) do
      local key = Config.patterns.collaborator (repository, collaborator)
      redis:set (key, Json.encode {
        repository   = repository,
        collaborator = collaborator,
      })
    end
  end
  redis:del (Config.patterns.lock (repository.full_name))
  redis:set_keepalive ()
  return ngx.exit (ngx.HTTP_OK)
end

return Server
