local Config   = require "lapis.config".get ()
local Et       = require "etlua"
local Http     = require "ardoises.jsonhttp".resty
local Lapis    = require "lapis"
local Model    = require "ardoises.server.model"
local Patterns = require "ardoises.patterns"
local Qless    = require "resty.qless"
local Util     = require "lapis.util"

local app  = Lapis.Application ()
app.layout = false
-- app:enable "etlua"

local function authenticate (self)
  if self.session.gh_id then
    self.account = Model.accounts:find {
      id = self.session.gh_id,
    }
    if self.account then
      return true
    end
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
  local qless = Qless.new (Config.redis)
  local queue = qless.queues ["ardoises"]
  queue:recur ("ardoises.server.job.editor.clean", {}, Config.clean.delay, {
    jid = "ardoises.server.job.editor.clean",
  })
  queue:recur ("ardoises.server.invitation", {}, Config.invitation.delay, {
    jid = "ardoises.server.invitation",
  })
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
  local account = Model.accounts:find {
    id = user.id,
  }
  if account then
    account:update {
      token = result.access_token,
    }
  elseif not account then
    Model.accounts:create {
      id    = user.id,
      token = result.access_token,
    }
  end
  self.account          = account
  self.session.gh_id    = self.account.id
  self.session.gh_token = self.account.token
  return { redirect_to = "/dashboard" }
end)

app:match ("/search(/:what)", function (self)
  if not authenticate (self) then
    return { redirect_to = "/overview.html" }
  end
  local what         = self.params.what or ""
  local user_repos   = {}
  local repositories = {}
  local result, status
  result, status = Http {
    url     = "https://api.github.com/user/repos",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. self.account.token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  assert (status == 200, status)
  for _, repository in ipairs (result) do
    if type (repository.description) ~= "string" then
      repository.description = ""
    end
    if repository.full_name  :match (what)
    or repository.description:match (what) then
      repository.user = {
        owner       = repository.owner,
        permissions = repository.permissions,
      }
      user_repos [repository.id] = repository
    end
  end
  result, status = Http {
    url     = "https://api.github.com/user/repos",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. Config.application.token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  assert (status == 200, status)
  for _, repo in ipairs (result) do
    local repository = user_repos [repo.id]
    if repository and repo.permissions.pull then
      repository.ardoises = {
        owner       = repo.owner,
        permissions = repo.permissions,
      }
      repositories [#repositories+1] = repository
    end
  end
  return {
    status = 200,
    json   = repositories,
  }
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
      ["Authorization"] = "token " .. self.account.token,
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
    queue:put ("ardoises.server.job.editor.start", {
      owner      = self.params.owner,
      repository = self.params.repository,
      branch     = self.params.branch,
    })
    return { status = 201 }
  end
end)

return app
