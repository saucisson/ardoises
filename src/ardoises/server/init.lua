local Config   = require "lapis.config".get ()
local Csrf     = require "lapis.csrf"
local Et       = require "etlua"
local Http     = require "ardoises.jsonhttp".resty
local Json     = require "rapidjson"
local Lapis    = require "lapis"
local Mime     = require "mime"
local Model    = require "ardoises.server.model"
local Patterns = require "ardoises.patterns"
local Qless    = require "resty.qless"
local Util     = require "lapis.util"

local app  = Lapis.Application ()
app.layout = false
app:enable "etlua"

local function authenticate (self)
  if self.session.user then
    return true
  end
  local authorization = Patterns.authorization:match (self.req.headers ["Authorization"] or "")
  if not authorization then
    return nil
  end
  local account = Model.accounts:find {
    token = authorization,
  }
  local user, status = Http {
    url     = "https://api.github.com/user",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. (authorization or ""),
      ["User-Agent"   ] = Config.application.name,
    },
  }
  if status ~= 200 then
    return nil
  end
  self.session.user = user
  if not account or Model.accounts:find {
    id = self.session.user.id,
  } then
    Model.accounts:create {
      id    = self.session.user.id,
      token = authorization,
    }
  end
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
  local qless = Qless.new (Config.redis)
  local queue = qless.queues ["ardoises"]
  if not qless.jobs:get "ardoises.server.job.editor.clean" then
    queue:recur ("ardoises.server.job.editor.clean", {}, Config.clean.delay, {
      jid = "ardoises.server.job.editor.clean",
    })
  end
  if not qless.jobs:get "ardoises.server.job.permissions" then
    queue:recur ("ardoises.server.job.permissions", {}, Config.permissions.delay, {
      jid = "ardoises.server.job.permissions",
    })
  end
  if authenticate (self) then
    local search = self.params.search or ""
    local starred, status = Http {
      url     = Et.render ("https://api.github.com/users/<%- user %>/starred", {
        user = self.session.user.login,
      }),
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. Config.application.token,
        ["User-Agent"   ] = Config.application.name,
      },
    }
    assert (status == 200, status)
    local stars = {}
    for _, repository in ipairs (starred) do
      stars [repository.id] = 1
    end
    local result = {}
    for _, t in ipairs (Model.permissions:select ([[ WHERE account = ? ]], self.session.user.id)) do
      local repo = Model.repositories:find {
        id = t.repository,
      }
      local repository   = Json.decode (repo.contents)
      result [#result+1] = repository
      repository.permission       = t.permission
      repository.user_permissions = {
        pull = t.permission == "read"
            or t.permission == "write",
        push = t.permission == "write",
      }
    end
    table.sort (result, function (l, r)
      return l.permission > r.permission -- write > read
         and (stars [l.id] or 0) > (stars [r.id] or 0) -- stars
         and l.full_name < r.full_name -- name
    end)
    self.search       = search or "search"
    self.repositories = result
    return {
      layout = "ardoises",
      render = "dashboard",
    }
  else
    return {
      layout = "ardoises",
      render = "overview",
    }
  end
end)

app:match ("/login", function (self)
  return {
    redirect_to = Et.render ("https://github.com/login/oauth/authorize?state=<%- state %>&scope=<%- scope %>&client_id=<%- client_id %>", {
      client_id = Config.application.id,
      state     = Mime.b64 (Csrf.generate_token (self)),
      scope     = Util.escape "user:email",
    })
  }
end)

app:match ("/logout", function (self)
  self.session.user = nil
  return { redirect_to = "/" }
end)

app:match ("/register", function (self)
  self.params.csrf_token = Mime.unb64 (self.params.state)
  if not Csrf.validate_token (self) then
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
  assert (status == 200, status)
  user.token = result.access_token
  local account = Model.accounts:find {
    id = user.id,
  }
  if account then
    account:update {
      token = user.token,
    }
  elseif not account then
    Model.accounts:create {
      id    = user.id,
      token = user.token,
    }
  end
  self.session.user = user
  return { redirect_to = "/" }
end)

app:match ("/editors/", "/editors/:owner/:repository(/:branch)", function (self)
  if not authenticate (self) then
    return { redirect_to = "/overview.html" }
  end
  local repository, status
  repository, status = Http {
    url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>", {
      owner      = self.params.owner,
      repository = self.params.repository,
    }),
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. self.session.user.token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  if status == 404 then
    return { status = 404 }
  end
  assert (status == 200, status)
  if not repository.permissions.pull then
    return { status = 403 }
  end
  repository, status = Http {
    url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>", {
      owner      = self.params.owner,
      repository = self.params.repository,
    }),
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. Config.application.token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  if status == 404 then
    return { status = 404 }
  end
  assert (status == 200, status)
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
  local repository_name = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", self.params)
  local editor = Model.editors:find {
    repository = repository_name,
  }
  if not editor then
    local qless = Qless.new (Config.redis)
    local queue = qless.queues ["ardoises"]
    queue:put ("ardoises.server.job.editor.start", {
      owner      = self.params.owner,
      repository = self.params.repository,
      branch     = self.params.branch,
    })
  end
  repeat
    _G.ngx.sleep (1)
    editor = editor and editor:update () or Model.editors:find {
               repository = repository_name,
             }
  until editor and editor.url
  return {
    layout = "ardoises",
    render = "editor",
  }
end)

return app
