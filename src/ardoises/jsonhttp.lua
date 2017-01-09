local Json = require "rapidjson"
local Util = require "lapis.util"
local JsonHttp = {}

local function wrap (what)
  return function (options)
    assert (type (options) == "table")
    local request  = {}
    request.url    = options.url
    request.method = options.method  or "GET"
    request.body   = options.body    and Json.encode (options.body, {
      sort_keys = true,
    })
    request.headers = {}
    for name, header in pairs (options.headers or  {}) do
      request.headers [name] = header
    end
    local query = {}
    for key, value in pairs (options.query or {}) do
      query [#query+1] = Util.encode (key) .. "=" .. Util.encode (value)
    end
    request.query = #query ~= 0 and table.concat (query, "&")
    request.headers ["Content-length"] = request.body and #request.body
    request.headers ["Content-type"  ] = request.body and "application/json"
    request.headers ["Accept"        ] = request.headers ["Accept"] or "application/json"
    local result = what (request)
    if result.body then
      local ok, json = pcall (Json.decode, result.body)
      if ok then
        result.body = json
      end
    end
    return result.body, result.status, result.headers
  end
end

JsonHttp.resty = wrap (function (request)
  assert (type (request) == "table")
  local Config = require "lapis.config".get ()
  local Httpr  = require "resty.http"
  local Redis  = require "resty.redis"
  local json   = {}
  local redis
  request.ssl_verify = false
  if request.method == "GET" then
    redis = Redis:new ()
    redis:set_timeout (1000) -- milliseconds
    assert (redis:connect (Config.redis.host, Config.redis.port))
    assert (redis:select  (Config.redis.database))
    json.request = Json.encode (request, {
      sort_keys = true,
    })
    local answer = redis:get (json.request)
    if answer ~= _G.ngx.null then
      json.answer = Json.decode (answer)
      request.headers ["If-None-Match"    ] = json.answer.headers ["ETag"         ]
      request.headers ["If-Modified-Since"] = json.answer.headers ["Last-Modified"]
    end
  end
  local client = Httpr.new ()
  client:set_timeout (1000) -- milliseconds
  local result = assert (client:request_uri (request.url, request))
  if result.status == 304 then
    redis:expire (json.request, 86400) -- 1 day
    return json.answer
  end
  if request.method == "GET" then
    json.answer = Json.encode ({
      status  = result.status,
      headers = result.headers,
      body    = result.body,
    }, {
      sort_keys = false,
    })
    redis:set (json.request, json.answer)
    redis:expire (json.request, 86400) -- 1 day
  end
  return result
end)

JsonHttp.copas = wrap (function (request)
  assert (type (request) == "table")
  local Httpc  = require "copas.http"
  local Ltn12  = require "ltn12"
  local result = {}
  request.sink   = Ltn12.sink.table (result)
  request.source = request.body  and Ltn12.source.string (request.body)
  local _, status, headers = Httpc.request (request)
  return {
    status  = status,
    headers = headers,
    body    = table.concat (result),
  }
end)

JsonHttp.default = wrap (function (request)
  assert (type (request) == "table")
  local Httpn = require "socket.http"
  local Https = require "ssl.https"
  local Ltn12 = require "ltn12"
  local result   = {}
  request.sink   = Ltn12.sink.table (result)
  request.source = request.body  and Ltn12.source.string (request.body)
  local http = request.url:match "https://" and Https or Httpn
  local _, status, headers = http.request (request)
  return {
    status  = status,
    headers = headers,
    body    = table.concat (result),
  }
end)

JsonHttp.js = wrap (function (request)
  assert (type (request) == "table")
  local Copas   = require "copas"
  local Adapter = require "ardoises.js"
  local running = {
    copas = Copas.running,
    co    = coroutine.running (),
  }
  local response, json, err
  local r1 = Adapter.window:fetch (request.url, Adapter.tojs {
    method   = request.method or "GET",
    headers  = request.headers,
    body     = request.body,
    mode     = "cors",
    redirect = "follow",
    cache    = "force-cache",
  })
  local r2 = r1 ["then"] (r1, function (_, r)
    assert (r.status >= 200 and r.status < 400)
    response = r
    return response:text ()
  end)
  local r3 = r2 ["then"] (r2, function (_, text)
    json = Json.decode (text)
    if running.copas then
      Copas.wakeup (running.copas)
    else
      coroutine.resume (running.co)
    end
  end)
  r2:catch (function (_, e)
    err = e
    if running.copas then
      Copas.wakeup (running.copas)
    else
      coroutine.resume (running.co)
    end
  end)
  r3:catch (function (_, e)
    err = e
    if running.copas then
      Copas.wakeup (running.copas)
    else
      coroutine.resume (running.co)
    end
  end)
  if running.copas then
    Copas.sleep (-math.huge)
  else
    coroutine.yield ()
  end
  if json then
    return {
      status  = response.status,
      headers = response.headers,
      body    = json,
    }
  else
    return nil, err
  end
end)

return JsonHttp
