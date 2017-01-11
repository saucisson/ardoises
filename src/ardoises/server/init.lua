local Config   = require "lapis.config".get ()
local Et       = require "etlua"
local Gettime  = require "socket".gettime
local Http     = require "ardoises.jsonhttp".resty
local Hmac     = require "openssl.hmac"
local Json     = require "rapidjson"
local Jwt      = require "resty.jwt"
local Lapis    = require "lapis"
local Model    = require "ardoises.server.model"
local Patterns = require "ardoises.patterns"
local Qless    = require "resty.qless"
local Redis    = require "resty.redis"
local Util     = require "lapis.util"

-- http://25thandclement.com/~william/projects/luaossl.pdf
local function tohex (b)
  local x = ""
  for i = 1, #b do
    x = x .. string.format ("%.2x", string.byte (b, i))
  end
  return x
end

local app  = Lapis.Application ()
app.layout = false
app:enable "etlua"

local function authenticate (self)
  if self.session.gh_id then
    self.account = Model.accounts:find {
      id = self.session.gh_id,
    }
    return true
  end
  local authorization = self.req.headers ["Authorization"] or ""
  authorization = Patterns.authorization:match (authorization)
  if not authorization then
    return nil
  end
  local account = Model.accounts:find {
    token = authorization,
  }
  if not account then
    local user, status = Http {
      url     = "https://api.github.com/user",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. authorization,
        ["User-Agent"   ] = Config.application.name,
      },
    }
    if status ~= 200 then
      return nil
    end
    account = Model.accounts:find {
      id = user.id,
    }
    if not account then
      account = Model.accounts:create {
        id    = user.id,
        token = authorization,
      }
    end
  end
  self.account = account
  return true
end

app.handle_error = function (_, error, trace)
  print (error)
  print (trace)
  return { status = 500 }
end

app.handle_404 = function ()
  return { status = 404 }
end

app:match ("/", function (self)
  if authenticate (self) then
    return { redirect_to = "/dashboard.html" }
  else
    return { redirect_to = "/overview.html" }
  end
end)

app:match ("/login", function ()
  return {
    redirect_to = Et.render ("https://github.com/login/oauth/authorize?state=<%- state %>&scope=<%- scope %>&client_id=<%- client_id %>", {
      client_id = Config.application.id,
      state     = Config.application.state,
      scope     = Util.escape "user:email",
    })
  }
end)

app:match ("/register", function (self)
  if self.params.state ~= Config.application.state then
    return { status = 400 }
  end
  local user, result, status
  result, status = Http {
    url     = "https://github.com/login/oauth/access_token",
    method  = "POST",
    headers = {
      ["Accept"    ] = "application/json",
      ["User-Agent"] = Config.application.name,
    },
    body    = {
      client_id     = Config.application.id,
      client_secret = Config.application.secret,
      state         = Config.application.state,
      code          = self.params.code,
    },
  }
  print (status)
  assert (status == 200, status)
  user, status = Http {
    url     = "https://api.github.com/user",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. result.access_token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  if status ~= 200 then
    return nil
  end
  local account = Model.accounts:find {
    id = user.id,
  }
  if account then
    account:update {
      token = result.access_token,
    }
  elseif not account then
    account = Model.accounts:create {
      id    = user.id,
      token = result.access_token,
    }
  end
  self.account          = account
  self.session.gh_id    = self.account.id
  self.session.gh_token = self.account.token
  return { redirect_to = "/dashboard.html" }
end)

app:match ("/events", function (self)
  _G.ngx.req.read_body ()
  local event     = self.req.headers ["X-GitHub-Event"   ]
  local signature = self.req.headers ["X-Hub-Signature"  ]
  local delivery  = self.req.headers ["X-GitHub-Delivery"]
  local body      = _G.ngx.req.get_body_data ()
  print ("event    : ", event)
  print ("body     : ", body)
  local digest    = tohex (Hmac.new (Config.integration.secret):final (body))
  if "sha1=" .. digest ~= signature then
    return { status = 403 }
  end
  body = Json.decode (body)
  if event == "integration_installation" then
  end
  return { status = 204 }
end)

app:match ("/search/:what", function (self)
  if not authenticate (self) then
    return { redirect_to = "/overview.html" }
  end
  local jwt = Jwt:sign (Config.integration.pem, {
    header  = {
      typ = "JWT",
      alg = "RS256",
    },
    payload = {
      iat = math.floor (Gettime ()),
      exp = math.floor (Gettime ()) + 60,
      iss = Config.integration.id,
    },
  })
  print (Json.encode {
    header  = {
      typ = "JWT",
      alg = "RS256",
    },
    payload = {
      iat = math.floor (Gettime ()),
      exp = math.floor (Gettime ()) + 60,
      iss = Config.integration.id,
    },
  })
  local installations, status = Http {
    url     = "https://api.github.com/integration/installations",
    method  = "GET",
    nocache = true,
    headers = {
      ["Authorization"] = "Bearer " .. jwt,
      ["Accept"       ] = "application/vnd.github.machine-man-preview+json",
    },
  }
  assert (status == 200)
  local redis = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  assert (redis:select  (Config.redis.database))
  for _, installation in ipairs (installations) do
    print (Json.encode (installation))
    local token = redis:get ("integration:" .. tostring (installation.id))
    if token == _G.ngx.null then
      local result
      result, status = Http {
        url     = installation.access_tokens_url,
        method  = "POST",
        headers = {
          ["Authorization"] = "Bearer " .. jwt,
          ["Accept"       ] = "application/vnd.github.machine-man-preview+json",
        },
      }
      assert (status == 201)
      redis:set    ("integration:" .. tostring (installation.id), result.token)
      redis:expire ("integration:" .. tostring (installation.id), 3500)
      token = result.token
    end
    print (installation.id, " : ", token)
    local repositories
    repositories, status = Http {
      url     = installation.repositories_url,
      method  = "GET",
      headers = {
        ["Authorization"] = "token " .. token,
        ["Accept"       ] = "application/vnd.github.machine-man-preview+json",
      },
    }
    assert (status == 200)
    print (Json.encode (repositories))
  end
  redis:set_keepalive (10 * 1000, 100)
  return { status = 200 }
end)

app:match ("/editors/", "/editors/:owner/:repository(/:branch)", function (self)
  if not authenticate (self) then
    return { redirect_to = "/overview.html" }
  end
  local repository, status = Http {
    url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>", {
      owner      = self.params.owner,
      repository = self.params.repository,
    }),
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. self.account.token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  if status ~= 200 then
    return { status = 404 }
  end
  if not repository.permissions.pull then
    return { status = 403 }
  end
  if not self.params.branch then
    return {
      redirect_to = self:url_for ("/editors/", {
        owner      = self.params.owner,
        repository = self.params.repository,
        branch     = repository.default_branch,
      })
    }
  end
  local editor = Model.editors:find {
    repository = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", self.params)
  }
  if editor and editor.url then
    return { redirect_to = editor.url }
  elseif editor then
    return { status = 202 }
  else
    local qless = Qless.new (Config.redis)
    local queue = qless.queues ["ardoises"]
    queue:put ("ardoises.server.editors.start", {
      owner      = self.params.owner,
      repository = self.params.repository,
      branch     = self.params.branch,
      token      = self.account.token,
    })
    queue:recur ("ardoises.server.editors.clean", {}, Config.clean.delay, {
      jid = "ardoises.server.editors.clean",
    })
    return { status = 201 }
  end
end)

return app
