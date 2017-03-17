local Json = require "rapidjson"
local Util = require "lapis.util"
local JsonHttp = {}

local function wrap (what)
  return function (options)
    assert (type (options) == "table")
    local request  = {}
    local answer   = {}
    request.url    = options.url
    request.method = options.method or "GET"
    request.body   = options.body   and Json.encode (options.body, {
      sort_keys = true,
    })
    request.headers = {}
    for name, header in pairs (options.headers or  {}) do
      request.headers [name] = header
    end
    request.query = Util.encode_query_string (options.query or {})
    request.headers ["Content-length"] = request.body and #request.body
    request.headers ["Content-type"  ] = request.body and "application/json"
    request.headers ["Accept"        ] = request.headers ["Accept"] or "application/json"
    local cache = not options.nocache
    repeat
      local result = what (request, cache)
      if result.body then
        local ok, json = pcall (Json.decode, result.body)
        if ok then
          result.body = json
        end
      end
      answer.status  = answer.status  or result.status
      answer.headers = answer.headers or result.headers
      if not answer.body then
        answer.body  = result.body
      else
        for _, entry in ipairs (result.body) do
          answer.body [#answer.body+1] = entry
        end
      end
      request.url   = nil
      request.query = nil
      request.body  = nil
      if result.headers ["Link"] and result.status == 304 then
        cache = "only"
      end
      for link in (result.headers ["Link"] or ""):gmatch "[^,]+" do
        request.url = link:match [[<([^>]+)>;%s*rel="next"]] or request.url
      end
    until not request.url
    return answer.body, answer.status, answer.headers
  end
end

JsonHttp.resty = wrap (function (request, cache)
  assert (type (request) == "table")
  local Config = require "lapis.config".get ()
  local Http   = require "resty.http"
  local Redis  = require "resty.redis"
  local json   = {}
  local redis  = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  assert (redis:select  (Config.redis.database))
  request.ssl_verify = false
  if cache and request.method == "GET" then
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
  local result
  if cache ~= "only" then
    local client = Http.new ()
    client:set_timeout (1000) -- milliseconds
    result = assert (client:request_uri (request.url, request))
  else
    result = json.answer
  end
  if result.status == 304 then
    redis:expire (json.request, Config.jsonhttp.delay) -- 1 day
    return json.answer
  end
  if cache and request.method == "GET" then
    json.answer = Json.encode ({
      status  = result.status,
      headers = result.headers,
      body    = result.body,
    }, {
      sort_keys = false,
    })
    redis:set    (json.request, json.answer)
    redis:expire (json.request, 86400) -- 1 day
  end
  redis:set_keepalive (10 * 1000, 100)
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
  if request.headers then
    request.headers ["User-Agent"] = nil
  end
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
