local Config = require "lapis.config".get ()
local Et     = require "etlua"
local Http   = require "ardoises.jsonhttp".resty
local Lapis  = require "lapis"
local Model  = require "ardoises.server.model"
local Qless  = require "resty.qless"
local Util   = require "lapis.util"

local app  = Lapis.Application ()
app.layout = false
app:enable "etlua"

local function get_token ()
  return {
    redirect_to = Et.render ("https://github.com/login/oauth/authorize?state=<%- state %>&scope=<%- scope %>&client_id=<%- client_id %>", {
      client_id = Config.gh_client_id,
      state     = Config.gh_oauth_state,
      scope     = Util.escape "user:email repo",
    })
  }
end

local function get_scopes (self)
  if not self.session.gh_id then
    return nil
  end
  self.account = Model.accounts:find {
    id = self.session.gh_id,
  }
  if not self.account
  or not self.account.token then
    return nil
  end
  local user, status, headers = Http {
    url     = "https://api.github.com/user",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. self.account.token,
      ["User-Agent"   ] = Config.gh_app_name,
    },
  }
  if status ~= 200 then
    return nil
  end
  self.user = user
  local header = headers ["X-OAuth-Scopes"] or ""
  local scopes = {}
  for scope in header:gmatch "[^,%s]+" do
    scopes [scope] = true
  end
  return scopes
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
  local scopes = get_scopes (self)
  if not scopes
  or scopes ["user:email"] == nil
  or scopes ["repo"      ] == nil then
    return get_token ()
  end
  return {
    status = 200,
    render = "main",
    layout = "layout",
  }
end)

app:match ("/editors/", "/editors/:owner/:repository(/:branch)", function (self)
  local scopes = get_scopes (self)
  if not scopes
  or scopes ["user:email"] == nil
  or scopes ["repo"      ] == nil then
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
    repository = repository.full_name,
    branch     = self.params.branch,
  }
  if editor and editor.url then
    return { redirect_to = editor.url }
  elseif editor then
    return { status = 202 }
  else
    local qless = Qless.new (Config.redis)
    local queue = qless.queues ["ardoises"]
    queue:put ("ardoises.server.editors.start", {
      repository = repository,
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
  local result, status
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
  local token = assert (result.access_token)
  result, status = Http {
    url     = "https://api.github.com/user",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. token,
      ["User-Agent"   ] = Config.gh_app_name,
    },
  }
  assert (status == 200, status)
  local account = Model.accounts:find {
    id = result.id,
  }
  if account then
    account:update {
      token = token,
    }
  else
    account = Model.accounts:create {
      id    = result.id,
      token = token,
    }
  end
  self.session.gh_id    = account.id
  self.session.gh_token = account.token
  return { redirect_to = "/" }
end)

return app
