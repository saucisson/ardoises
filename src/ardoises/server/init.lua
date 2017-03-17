local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Cookie   = require "resty.cookie"
local Http     = require "ardoises.server.jsonhttp"
local Json     = require "rapidjson"
local Jwt      = require "resty.jwt"
local Lustache = require "lustache"
local Redis    = require "resty.redis"
local Url      = require "net.url"

local Config  = {
  pattern = "ardoises:info:{{{what}}}",
  docker = assert (Url.parse (os.getenv "DOCKER_URL")),
  redis  = assert (Url.parse (os.getenv "REDIS_URL")),
  application = {
    id     = assert (os.getenv "APPLICATION_ID"),
    secret = assert (os.getenv "APPLICATION_SECRET"),
  },
}

local Server = {}

function Server.login ()
  local url           = Url.parse "https://github.com/login/oauth/authorize"
  url.query.client_id = Config.application.id
  url.query.scope     = "user:email"
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
    httponly = false,
    secure   = false,
    samesite = "Strict",
  }
  return ngx.exit (204)
end

function Server.register ()
  local query = ngx.req.get_uri_args()
  local token = Jwt:verify (Config.application.secret, query.state)
  if not token
  or not token.payload
  or not token.payload.csrf then
    return ngx.exit (403)
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
  if status ~= 200
  or not result.access_token then
    return ngx.exit (500)
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
  if status ~= 200 then
    return ngx.exit (500)
  end
  local key  = Lustache:render (Config.pattern, {
    what = user.login
  })
  repeat
    redis:watch (key)
    local value = redis:get (key)
    local info  = value ~= ngx.null
              and Json.decode (value)
               or {}
    for k, v in pairs (user) do
      info [k] = v
    end
    redis:multi ()
    redis:set (key, Json.encode (info))
    local success = redis:exec ()
  until success
  local cookie = Cookie:new ()
  cookie:set {
    expires  = nil,
    httponly = false,
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
  return ngx.exit (204)
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
