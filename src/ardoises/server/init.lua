local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Config   = require "ardoises.server.config"
local Cookie   = require "resty.cookie"
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
    Lpeg.P"Token:"
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

function Server.include (what)
  local file, err = io.open ("/static/" .. what .. ".template", "r")
  if not file then
    print (err)
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  local template = assert (file:read "*a")
  assert (file:close ())
  return template
end

function Server.template (what, data)
  data = data or {}
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
              and "Token: " .. field
               or headers ["Authorization"]
  if not header then
    return not noexit and ngx.exit (ngx.HTTP_UNAUTHORIZED) or nil
  end
  local token = Patterns.authorization:match (header)
  if not token then
    return not noexit and ngx.exit (ngx.HTTP_UNAUTHORIZED) or nil
  end
  token = Jwt:verify (Config.application.secret, token)
  if not token then
    return not noexit and ngx.exit (ngx.HTTP_UNAUTHORIZED) or nil
  end
  local redis = Redis:new ()
  if not redis:connect (Config.redis.host, Config.redis.port) then
    return not noexit and ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR) or nil
  end
  local user = redis:get (Config.patterns.user (token.payload))
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
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    user    = user,
    content = user
          and Server.include "dashboard"
           or Server.include "overview"
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
    if redis:setnx ("ardoises:lock:register", "locked") then
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
  redis:del "ardoises:lock:register"
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
  user.token = result.access_token
  redis:set (key, Json.encode (user))
  local cookie = Cookie:new ()
  cookie:set {
    expires  = nil,
    httponly = true,
    secure   = false,
    samesite = "Strict",
    key      = "Ardoises-Token",
    value    = Jwt:sign (Config.application.secret, {
      header  = {
        typ = "JWT",
        alg = "HS256",
      },
      payload = {
        login = user.login,
      },
    }),
  }
  return ngx.redirect "/"
end

function Server.user ()
  local _     = Server.authenticate ()
  local query = ngx.req.get_uri_args ()
  local redis = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  local result = redis:get (Config.patterns.user (query))
  if result == ngx.null or not result then
    return ngx.exit (ngx.HTTP_NOT_FOUND)
  end
  result = Json.decode (result)
  if not result then
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  ngx.say (Json.encode {
    login      = result.login,
    name       = result.name,
    company    = result.company,
    location   = result.location,
    bio        = result.bio,
    avatar_url = result.avatar_url,
  })
  return ngx.exit (ngx.HTTP_OK)
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

function Server.my_repositories ()
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
      }, { login = user.login }),
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
  else
    redis:set_keepalive ()
    return ngx.exit (ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  redis:set_keepalive ()
  return ngx.exit (ngx.HTTP_OK)
end

return Server

-- local Http     = require "ardoises.server.jsonhttp"
-- local Json     = require "rapidjson"
-- local Jwt      = require "jwt"
-- local Mime     = require "mime"
-- local Patterns = require "ardoises.patterns"
--
-- local function authenticate (self)
--   if self.session.user then
--     return true
--   end
--   local authorization = Patterns.authorization:match (self.req.headers ["Authorization"] or "")
--   if not authorization then
--     return nil
--   end
--   local account = Model.accounts:find {
--     token = authorization,
--   }
--   if account then
--     self.session.user = Json.decode (account.contents)
--     self.session.user.token = authorization
--     return true
--   end
--   local user, status = Http {
--     url     = "https://api.github.com/user",
--     method  = "GET",
--     headers = {
--       ["Accept"       ] = "application/vnd.github.v3+json",
--       ["Authorization"] = "token " .. (authorization or ""),
--       ["User-Agent"   ] = Config.application.name,
--     },
--   }
--   if status ~= 200 then
--     return nil
--   end
--   pcall (function ()
--     Model.accounts:create {
--       id       = user.id,
--       token    = authorization,
--       contents = Json.encode (user),
--     }
--   end)
--   assert (Model.accounts:find {
--     id = user.id,
--   })
--   self.session.user = user
--   self.session.user.token = authorization
--   return true
-- end
--
-- app.handle_error = function (self, error, trace)
--   print (error)
--   print (trace)
--   if self.req.headers.accept == "application/json" then
--     return {
--       status = 500,
--       json   = {},
--     }
--   else
--     self.status = 500
--     return {
--       status = 500,
--       layout = "ardoises",
--       render = "error",
--     }
--   end
-- end
--
-- app.handle_404 = function (self)
--   if self.req.headers.accept == "application/json" then
--     return {
--       status = 500,
--       json   = {},
--     }
--   else
--     self.status = 404
--     return {
--       status = 404,
--       layout = "ardoises",
--       render = "error",
--     }
--   end
-- end
--
-- app:match ("/", function (self)
--   if authenticate (self) then
--     local result = {}
--     local request = Et.render ([[
--       permissions.permission, repositories.contents
--       FROM permissions, repositories
--       WHERE permissions.account = <%- account %>
--         AND permissions.repository = repositories.id
--     ]], {
--       account = self.session.user.id,
--     })
--     for _, t in ipairs (Database.select (request)) do
--       local repository = Json.decode (t.contents)
--       repository.description = repository.description == Json.null
--                            and ""
--                             or repository.description
--       if repository.full_name  :match (self.params.search or "")
--       or repository.description:match (self.params.search or "") then
--         result [#result+1] = repository
--         repository.permission       = t.permission
--         repository.user_permissions = {
--           pull = t.permission == "read"
--               or t.permission == "write",
--           push = t.permission == "write",
--         }
--       end
--     end
--     if self.req.headers.accept == "application/json" then
--       return {
--         status = 200,
--         json   = result,
--       }
--     else
--       table.sort (result, function (l, r)
--         return l.permission > r.permission -- write > read
--       end)
--       table.sort (result, function (l, r)
--         return l.pushed_at > r.pushed_at -- last push
--       end)
--       table.sort (result, function (l, r)
--         return l.full_name < r.full_name -- name
--       end)
--       self.search       = self.params.search
--       self.repositories = result
--       return {
--         status = 200,
--         layout = "ardoises",
--         render = "dashboard",
--       }
--     end
--   else
--     if self.req.headers.accept == "application/json" then
--       return {
--         status = 200,
--         json   = {},
--       }
--     else
--       return {
--         status = 200,
--         layout = "ardoises",
--         render = "overview",
--       }
--     end
--   end
-- end)
--
-- app:match ("/login", function (self)
--   return {
--     redirect_to = Et.render ("https://github.com/login/oauth/authorize?state=<%- state %>&scope=<%- scope %>&client_id=<%- client_id %>", {
--       client_id = Config.application.id,
--       state     = Mime.b64 (Csrf.generate_token (self)),
--       scope     = Util.escape "user:email",
--     })
--   }
-- end)
--
-- app:match ("/logout", function (self)
--   self.session.user = nil
--   return { redirect_to = "/" }
-- end)
--
-- app:match ("/register", function (self)
--   self.params.csrf_token = Mime.unb64 (self.params.state)
--   assert (Csrf.validate_token (self))
--   local user, result, status
--   result, status = Http {
--     url     = "https://github.com/login/oauth/access_token",
--     method  = "POST",
--     headers = {
--       ["Accept"    ] = "application/json",
--       ["User-Agent"] = Config.application.name,
--     },
--     body    = {
--       client_id     = Config.application.id,
--       client_secret = Config.application.secret,
--       state         = Config.application.state,
--       code          = self.params.code,
--     },
--   }
--   assert (status == 200, status)
--   user, status = Http {
--     url     = "https://api.github.com/user",
--     method  = "GET",
--     headers = {
--       ["Accept"       ] = "application/vnd.github.v3+json",
--       ["Authorization"] = "token " .. result.access_token,
--       ["User-Agent"   ] = Config.application.name,
--     },
--   }
--   assert (status == 200, status)
--   local account = Model.accounts:find {
--     id = user.id,
--   }
--   if account then
--     account:update {
--       token    = user.token,
--       contents = Json.encode (user),
--     }
--   elseif not account then
--     pcall (function ()
--       Model.accounts:create {
--         id       = user.id,
--         token    = user.token,
--         contents = Json.encode (user),
--       }
--     end)
--     assert (Model.accounts:find {
--       id = user.id,
--     })
--   end
--   self.session.user = user
--   self.session.user.token = result.access_token
--   return { redirect_to = "/" }
-- end)
--
-- app:match ("/editors/", "/editors/:owner/:repository(/:branch)", function (self)
--   if not authenticate (self) then
--     return { redirect_to = "/" }
--   end
--   local repository, status
--   for _, token in ipairs { self.session.user.token, Config.application.token } do
--     repository, status = Http {
--       url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>", {
--         owner      = self.params.owner,
--         repository = self.params.repository,
--       }),
--       method  = "GET",
--       headers = {
--         ["Accept"       ] = "application/vnd.github.v3+json",
--         ["Authorization"] = "token " .. tostring (token),
--         ["User-Agent"   ] = Config.application.name,
--       },
--     }
--     if status == 404 then
--       return { status = 404 }
--     end
--     assert (status == 200, status)
--     if not repository.permissions.pull then
--       return { status = 403 }
--     end
--   end
--   if not self.params.branch then
--     return {
--       redirect_to = self:url_for ("/editors/", {
--         owner      = self.params.owner,
--         repository = self.params.repository,
--         branch     = repository.default_branch,
--       })
--     }
--   end
--   local repository_name = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", self.params)
--   local editor = Model.editors:find {
--     repository = repository_name,
--   }
--   if not editor then
--     local qless = Qless.new (Config.redis)
--     local queue = qless.queues ["ardoises"]
--     queue:put ("ardoises.server.job.editor.start", {
--       owner      = self.params.owner,
--       repository = self.params.repository,
--       branch     = self.params.branch,
--     })
--   end
--   repeat
--     _G.ngx.sleep (1)
--     editor = editor
--          and editor:update ()
--           or Model.editors:find {
--                repository = repository_name,
--              }
--   until editor and editor.url
--   repository.editor_url = editor.url
--   repository.branch     = self.params.branch
--   if self.req.headers.accept == "application/json" then
--     return {
--       status = 200,
--       json   = repository,
--     }
--   else
--     self.user       = self.session.user
--     self.repository = repository
--     return {
--       status = 200,
--       layout = "ardoises",
--       render = "editor",
--     }
--   end
-- end)
--
-- return app
