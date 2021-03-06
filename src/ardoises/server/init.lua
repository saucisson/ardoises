local Config   = require "ardoises.config"
local Cookie   = require "resty.cookie"
local Gettime  = require "socket".gettime
local Http     = require "ardoises.jsonhttp.resty-redis"
local Hmac     = require "openssl.hmac"
local Json     = require "rapidjson"
local Jwt      = require "resty.jwt"
local Keys     = require "ardoises.server.keys"
local Lustache = require "lustache"
local Patterns = require "ardoises.patterns"
local Redis    = require "resty.redis"
local Url      = require "net.url"

local function localrepo (var)
  return {
    owner          = { login = var.owner },
    name           = var.name,
    full_name      = var.owner .. "/" .. var.name,
    default_branch = var.branch,
    permissions    = {
      admin = true,
      push  = true,
      pull  = true,
    },
  }
end

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
    if not redis:connect (Config.redis.url.host, Config.redis.url.port) then
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
  data           = data or {}
  local file     = assert (io.open ("/static/" .. what .. ".template", "r"))
  local template = assert (file:read "*a")
  assert (file:close ())
  data.configuration = Json.encode (data)
  return Lustache:render (template, data)
end

local function register ()
  local query = ngx.req.get_uri_args ()
  if query.code and query.state then
    _G.ngx.header ["Content-type"] = "text/html"
    ngx.say (Server.template ("index", {
      server = Url.build (Config.ardoises.url),
      code   = "ardoises.www.register",
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
  local token = Jwt:verify (Config.github.secret, query.state)
  if not token
  or not token.payload
  or not token.payload.csrf then
    return { status = ngx.HTTP_UNAUTHORIZED }
  end
  local lock = Keys.lock "register"
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
      client_id     = Config.github.id,
      client_secret = Config.github.secret,
      state         = query.state,
      code          = query.code,
    },
  }
  context.redis:del (Keys.lock "register")
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
  local key = Keys.user (user)
  user.tokens = {
    github   = result.access_token,
    ardoises = Jwt:sign (Config.github.secret, {
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
  -- FIXME
  -- local cookie = Cookie:new ()
  -- cookie:set {
  --   key      = "Ardoises-Token",
  --   expires  = nil,
  --   httponly = true,
  --   secure   = true,
  --   samesite = "Strict",
  --   value    = user.tokens.ardoises,
  -- }
  ngx.say (Json.encode {
    user   = user,
    cookie = {
      key      = "Ardoises-Token",
      expires  = nil,
      httponly = true,
      secure   = true,
      samesite = "Strict",
      value    = user.tokens.ardoises,
    },
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
    local jwt = Jwt:verify (Config.github.secret, token)
    if not jwt then
      return nil, ngx.HTTP_UNAUTHORIZED
    end
    local info = context.redis:get (Keys.user (jwt.payload))
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
    local url = Url.parse (Url.build (Config.ardoises.url))
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
    server  = Url.build (Config.ardoises.url),
    user    = user,
    code    = "ardoises.www.dashboard",
  }))
  return { status = ngx.HTTP_OK }
end)

Server.overview = wrap (function (context)
  local user = Server.authenticate (context, {
    optional = true,
  })
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    server = Url.build (Config.ardoises.url),
    user   = user,
    code   = "ardoises.www.overview",
  }))
  return { status = ngx.HTTP_OK }
end)

Server.view = wrap (function (context)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
  local repository
  if ngx.var.owner == "-" then
    repository = localrepo (ngx.var)
  else
    -- get repository:
    local rkey = Keys.repository {
      owner = { login = ngx.var.owner },
      name  = ngx.var.name,
    }
    repository = context.redis:get (rkey)
    if repository == ngx.null or not repository then
      return { status = ngx.HTTP_NOT_FOUND }
    end
    repository = assert (Json.decode (repository))
    -- check collaborator:
    local ckey = Keys.collaborator ({
      owner = { login = ngx.var.owner },
      name  = ngx.var.name,
    }, user)
    local collaboration = context.redis:get (ckey)
    if collaboration == ngx.null or not collaboration then
      if repository.private then
        return { status = ngx.HTTP_FORBIDDEN }
      end
    else
      collaboration = assert (Json.decode (collaboration))
      repository    = collaboration.repository
    end
  end
  -- answer:
  _G.ngx.header ["Content-type"] = "text/html"
  ngx.say (Server.template ("index", {
    server     = Url.build (Config.ardoises.url),
    user       = user,
    repository = repository,
    branch     = ngx.var.branch,
    code       = "ardoises.www.editor",
  }))
  return { status = ngx.HTTP_OK }
end)

Server.login = wrap (function ()
  local query            = ngx.req.get_uri_args ()
  local url              = Url.parse "https://github.com/login/oauth/authorize"
  local redirect         = Url.parse (Url.build (Config.ardoises.url))
  redirect.path          = query.redirect_uri or "/"
  url.query.redirect_uri = Url.build (redirect)
  url.query.client_id    = Config.github.id
  url.query.scope        = "user:email admin:repo_hook"
  url.query.state        = Jwt:sign (Config.github.secret, {
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
    secure   = true,
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
    tokens     = user.tokens,
  })
  return { status = ngx.HTTP_OK }
end)

Server.my_ardoises = wrap (function (context)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
  local seen   = {}
  local result = {}
  -- find collaborators in database:
  local cursor = 0
  repeat
    local res = context.redis:scan (cursor,
      "match", Keys.collaborator ({
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
        local repository = context.redis:get (Keys.repository (entry.repository))
        entry.repository = Json.decode (repository)
        result [#result+1] = entry
        seen   [entry.repository.full_name] = true
      end
    end
  until cursor == "0"
  -- find public repositories:
  cursor = 0
  repeat
    local res = context.redis:scan (cursor,
      "match", Keys.repository {
        owner = { login = "*" },
        name  = "*",
      },
      "count", 100)
    if res == ngx.null or not res then
      break
    end
    cursor = res [1]
    local keys = res [2]
    for _, key in ipairs (keys) do
      local repository = context.redis:get (key)
      if repository ~= ngx.null and repository then
        repository = Json.decode (repository)
        if not seen [repository.full_name] and not repository.private then
          local collaborator = Json.decode (Json.encode (user))
          collaborator.permissions = {
            pull  = true,
            push  = false,
            admin = false,
          }
          result [#result+1] = {
            repository   = repository,
            collaborator = collaborator,
          }
          seen [repository.full_name] = true
        end
      end
    end
  until cursor == "0"
  ngx.say (Json.encode (result))
  return { status = ngx.HTTP_OK }
end)

Server.my_tools = wrap (function (context)
  local user, err = Server.authenticate (context)
  if not user then
    return { status = err }
  end
  local result = {}
  -- find tools in database:
  local cursor = 0
  repeat
    local res = context.redis:scan (cursor,
      "match", Keys.tool (user, { id = "*" }),
      "count", 100)
    if res == ngx.null or not res then
      break
    end
    cursor = res [1]
    local keys = res [2]
    for _, key in ipairs (keys) do
      local entry = context.redis:get (key)
      if entry ~= ngx.null and entry then
        result [#result+1] = Json.decode (entry)
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
  if ngx.var.owner == "-" then
    local token = Jwt:sign (Config.github.secret, {
      header  = {
        typ = "JWT",
        alg = "HS256",
      },
      payload = {
        login   = user.login,
        ardoise = Lustache:render ("{{{owner}}}/{{{name}}}:{{{branch}}}", ngx.var),
      },
    })
    local repo = localrepo (ngx.var)
    ngx.say (Json.encode {
      token      = token,
      repository = repo,
      branch     = ngx.var.branch,
      editor_url = Lustache:render ("wss://{{{domain}}}.localtunnel.me", {
        domain = ngx.var.branch,
      }),
    })
    return { status = ngx.HTTP_OK }
  end
  -- get repository:
  local rkey = Keys.repository {
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }
  local repository = context.redis:get (rkey)
  if repository == ngx.null or not repository then
    return { status = ngx.HTTP_NOT_FOUND }
  end
  repository = assert (Json.decode (repository))
  -- check collaborator:
  local ckey = Keys.collaborator ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, user)
  local collaboration = context.redis:get (ckey)
  if collaboration == ngx.null or not collaboration then
    collaboration = nil
    if repository.private then
      return { status = ngx.HTTP_FORBIDDEN }
    end
  else
    collaboration = assert (Json.decode (collaboration))
    repository    = collaboration.repository
  end
  -- get editor:
  local lock = Keys.lock (Lustache:render ("editor:{{{owner}}}/{{{name}}}/{{{branch}}}", ngx.var))
  while true do
    if context.redis:setnx (lock, "locked") == 1 then
      context.redis:expire (lock, Config.locks.timeout)
      break
    end
    ngx.sleep (0.1)
  end
  local key = Keys.editor ({
    owner = { login = ngx.var.owner },
    name  = ngx.var.name,
  }, ngx.var.branch)
  local editor = context.redis:get (key)
  if editor == ngx.null or not editor then
    local info, status = Http {
      url    = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}/json", {
        host = Config.docker.url.host,
        port = Config.docker.url.port,
        id   = Config.docker.container,
      }),
      method = "GET",
    }
    assert (status == ngx.HTTP_OK, status)
    local _, network = next (info.NetworkSettings.Networks)
    local ninfo, nstatus = Http {
      url    = Lustache:render ("http://{{{host}}}:{{{port}}}/networks/{{{id}}}", {
        host = Config.docker.url.host,
        port = Config.docker.url.port,
        id   = network.NetworkID,
      }),
      method = "GET",
    }
    assert (nstatus == ngx.HTTP_OK, nstatus)
    local container
    for id, v in pairs (ninfo.Containers) do
      if v.Name:match "clean" then
        container = id
        break
      end
    end
    local cinfo, cstatus = Http {
      url    = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}/json", {
        host = Config.docker.url.host,
        port = Config.docker.url.port,
        id   = container,
      }),
      method = "GET",
    }
    assert (cstatus == ngx.HTTP_OK, cstatus)
    local service
    service, status = Http {
      url     = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/create", {
        host = Config.docker.url.host,
        port = Config.docker.url.port,
      }),
      method  = "POST",
      timeout = 120,
      body    = {
        Entrypoint   = "lua",
        Cmd          = {
          "-l",
          "ardoises.editor.bin",
        },
        Image        = cinfo.Image,
        ExposedPorts = {
          ["8080/tcp"] = {},
        },
        Volumes      = cinfo.Config.Volumes,
        HostConfig   = {
          PublishAllPorts = false,
          NetworkMode     = info.HostConfig.NetworkMode,
          Binds           = cinfo.HostConfig.Binds,
        },
        Env = {
          "ARDOISES_URL="    .. Url.build (Config.ardoises.url),
          "ARDOISES_BRANCH=" .. Lustache:render ("{{{owner}}}/{{{name}}}:{{{branch}}}", ngx.var),
          "ARDOISES_TOKEN="  .. Config.github.token,
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
        host = Config.docker.url.host,
        port = Config.docker.url.port,
        id   = service.Id,
      }),
    }
    assert (status == ngx.HTTP_NO_CONTENT, status)
    local start = Gettime ()
    local docker_url = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}", {
      host = Config.docker.url.host,
      port = Config.docker.url.port,
      id   = service.Id,
    })
    context.redis:set (key, Json.encode {
      repository = repository,
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
        _, network = next (info.NetworkSettings.Networks)
        context.redis:set (key, Json.encode {
          repository = repository,
          docker_id  = service.Id,
          created_at = created_at,
          started_at = Gettime (),
          target_url = Lustache:render ("http://{{{host}}}:8080", {
            host = network.IPAddress,
          }),
          editor_url = Url.build {
            scheme = "wss",
            host   = Config.ardoises.url.host,
            port   = Config.ardoises.url.port,
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
  local token = Jwt:sign (Config.github.secret, {
    header  = {
      typ = "JWT",
      alg = "HS256",
    },
    payload = {
      login   = user.login,
      ardoise = Lustache:render ("{{{owner}}}/{{{name}}}:{{{branch}}}", ngx.var),
    },
  })
  repository.permissions = collaboration
                       and collaboration.collaborator.permissions
                        or repository.permissions
  ngx.say (Json.encode {
    token      = token,
    repository = repository,
    branch     = ngx.var.branch,
    editor_url = editor.editor_url,
  })
  return { status = ngx.HTTP_OK }
end)

Server.check_token = wrap (function (context)
  local headers = ngx.req.get_headers ()
  local header  = headers ["Authorization"]
  if not header then
    return { status = ngx.HTTP_UNAUTHORIZED }
  end
  local token = Patterns.authorization:match (header)
  if not token then
    return { status = ngx.HTTP_UNAUTHORIZED }
  end
  token = Jwt:verify (Config.github.secret, token)
  if not token
  or not token.payload then
    return { status = ngx.HTTP_UNAUTHORIZED }
  end
  local branch = Patterns.branch:match (token.payload.ardoise)
  if branch.owner == "-" then
    ngx.say (Json.encode {
      user       = { login = "-" },
      repository = localrepo {
        owner  = branch.owner,
        name   = branch.repository,
        branch = branch.branch,
      },
    })
    return { status = ngx.HTTP_OK }
  end
  local user = context.redis:get (Keys.user (token.payload))
  if user == ngx.null or not user then
    return { status = ngx.HTTP_UNAUTHORIZED }
  end
  user = assert (Json.decode (user))
  do
    local emails, status = Http {
      url     = "https://api.github.com/user/emails",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. tostring (user.tokens.github),
        ["User-Agent"   ] = "Ardoises",
      },
    }
    if status ~= 200 then
      return { status = ngx.HTTP_UNAUTHORIZED }
    end
    for _, t in ipairs (emails) do
      if t.primary then
        user.email = t.email
      end
    end
  end
  assert (user.email)
  do
    local repository, status = Http {
      url     = Lustache:render ("https://api.github.com/repos/{{{owner}}}/{{{name}}}", {
        owner = branch.owner,
        name  = branch.repository,
      }),
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. tostring (user.tokens.github),
        ["User-Agent"   ] = "Ardoises",
      },
    }
    if status ~= 200 then
      return { status = ngx.HTTP_UNAUTHORIZED }
    end
    ngx.say (Json.encode {
      user       = user,
      repository = repository,
    })
  end
  return { status = ngx.HTTP_OK }
end)

Server.websocket = wrap (function (context)
  local key = Keys.editor ({
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
  local hmac    = Hmac.new (Config.github.secret)
  local headers = ngx.req.get_headers ()
  local data    = ngx.req.get_body_data ()
  if not data then
    local filename = ngx.req.get_body_file ()
    if filename then
      local file = io.open (filename, "r")
      data = assert (file:read "*a")
      assert (file:close ())
    end
  end
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
  local lock = Keys.lock (repository.full_name)
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
      "match", Keys.collaborator (repository, { login = "*" }),
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
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. Config.github.token,
      ["User-Agent"   ] = "Ardoises",
    },
  }
  if status >= 300 and status < 500 then
    -- delete repository:
    context.redis:del (Keys.repository (repository))
    -- delete webhook(s):
    local function create ()
      local user = context.redis:get (Keys.user (repository.owner))
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
        if hook.config.url:find (Url.build (Config.ardoises.url), 1, true) then
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
    end
    create ()
  elseif status == 200 then
    -- update readme:
    local readme
    readme, status = Http {
      url     = repository.url .. "/readme",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.3.html",
        ["Authorization"] = "token " .. Config.github.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    if status == ngx.HTTP_OK then
      repository.readme = readme
    end
    -- get branches:
    local branches
    branches, status = Http {
      url     = repository.branches_url:gsub ("{/branch}", ""),
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.loki-preview+json",
        ["Authorization"] = "token " .. Config.github.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    assert (status == ngx.HTTP_OK, status)
    repository.branches = branches
    for _, branch in ipairs (branches) do
      -- update readme:
      readme, status = Http {
        url     = repository.url .. "/readme",
        query   = { ref = branch.name },
        method  = "GET",
        headers = {
          ["Accept"       ] = "application/vnd.github.3.html",
          ["Authorization"] = "token " .. Config.github.token,
          ["User-Agent"   ] = "Ardoises",
        },
      }
      if status == ngx.HTTP_OK then
        branch.readme = readme
      end
    end
    -- update repository:
    context.redis:set (Keys.repository (repository), Json.encode (repository))
    -- update collaborators:
    for _, collaborator in ipairs (collaborators) do
      local key = Keys.collaborator (repository, collaborator)
      context.redis:set (key, Json.encode {
        repository   = {
          owner = { login = repository.owner.login },
          name  = repository.name,
        },
        collaborator = collaborator,
      })
    end
  end
  context.redis:del (Keys.lock (repository.full_name))
  return { status = ngx.HTTP_OK }
end)

return Server
