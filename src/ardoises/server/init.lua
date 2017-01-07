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
app:enable "etlua"

local function get_token ()
  return {
    redirect_to = Et.render ("https://github.com/login/oauth/authorize?state=<%- state %>&scope=<%- scope %>&client_id=<%- client_id %>", {
      client_id = Config.gh_client_id,
      state     = Config.gh_oauth_state,
      scope     = Util.escape "user:email repo", -- delete_repo
    })
  }
end

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
        ["User-Agent"   ] = Config.gh_app_name,
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

app:match ("/", "/", function (self)
  if not authenticate (self) then
    return get_token ()
  end
  return {
    status = 200,
    render = "main",
    layout = "layout",
  }
end)

app:match ("/editors/", "/editors/:owner/:repository(/:branch)", function (self)
  if not authenticate (self) then
    return get_token ()
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
      ["User-Agent"   ] = Config.gh_app_name,
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

app:match ("/newuser", "/newuser", function (self)
  if self.params.state ~= Config.gh_oauth_state then
    return { status = 400 }
  end
  local user, result, status
  result, status = Http {
    url     = "https://github.com/login/oauth/access_token",
    method  = "POST",
    headers = {
      ["Accept"    ] = "application/json",
      ["User-Agent"] = Config.gh_app_name,
    },
    body    = {
      client_id     = Config.gh_client_id,
      client_secret = Config.gh_client_secret,
      state         = Config.gh_oauth_state,
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
      ["User-Agent"   ] = Config.gh_app_name,
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
  return { redirect_to = "/" }
end)

return app
