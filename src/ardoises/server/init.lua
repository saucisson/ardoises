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
  if self.session.gh_id then
    self.account = Model.accounts:find {
      id = self.session.gh_id,
    }
  end
  local authorization
  if not self.account then
    authorization = self.req.headers ["Authorization"] or ""
    authorization = Patterns.authorization:match (authorization)
    if not authorization then
      return nil
    end
    self.account = Model.accounts:find {
      token = authorization,
    }
  end
  local user, status = Http {
    url     = "https://api.github.com/user",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. (authorization or self.account.token or ""),
      ["User-Agent"   ] = Config.application.name,
    },
  }
  if status ~= 200 then
    return nil
  end
  if not self.account then
    self.account = Model.accounts:find {
      id = user.id,
    }
  end
  if not self.account then
    self.account = Model.accounts:create {
      id    = user.id,
      token = authorization,
    }
  end
  self.user = user
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
  if not qless.jobs:get "ardoises.server.job.invitation" then
    queue:recur ("ardoises.server.job.invitation", {}, Config.invitation.delay, {
      jid = "ardoises.server.job.invitation",
    })
  end
  if authenticate (self) then
    local search = self.params.search or ""
    local result = {}
    local repositories, collaborator, starred, status
    starred, status = Http {
      url     = Et.render ("https://api.github.com/users/<%- user %>/starred", {
        user = self.user.login,
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
    for _, star in ipairs (starred) do
      stars [star.id] = star
    end
    repositories, status = Http {
      url     = "https://api.github.com/user/repos",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. Config.application.token,
        ["User-Agent"   ] = Config.application.name,
      },
    }
    assert (status == 200, status)
    local threads = {}
    for _, repository in ipairs (repositories) do
      threads [#threads+1] = _G.ngx.thread.spawn (function ()
        collaborator, status = Http {
          url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>/collaborators/<%- user %>/permission", {
            owner      = repository.owner.login,
            repository = repository.name,
            user       = self.user.login,
          }),
          method  = "GET",
          headers = {
            ["Accept"       ] = "application/vnd.github.korra-preview+json",
            ["Authorization"] = "token " .. Config.application.token,
            ["User-Agent"   ] = Config.application.name,
          },
        }
        assert (status == 200, status)
        if collaborator.permission == "none" then
          return
        end
        if  not repository.full_name  :match (search)
        and not repository.description:match (search) then
          return
        end
        repository.can_write = {
          ardoises = repository.permissions.push,
          user     = collaborator.permission == "admin"
                  or collaborator.permission == "write"
        }
        repository.description = repository.description == Json.null
                             and ""
                              or repository.description
        result [#result+1] = repository
      end)
    end
    for _, co in ipairs (threads) do
      _G.ngx.thread.wait (co)
    end
    table.sort (result, function (l, r)
      return l.pushed_at > r.pushed_at
    end)
    table.sort (result, function (l, r)
      return (stars [l.id] or 0) > (stars [r.id] or 0)
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
  self.session.gh_id    = nil
  self.session.gh_token = nil
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
