local Config   = require "ardoises.config"
local Common   = require "ardoises.jsonhttp.common"
local Json     = require "rapidjson"
local Http     = require "socket.http"
local Https    = require "ssl.https"
local Ltn12    = require "ltn12"
local Lustache = require "lustache"
local Redis    = require "redis"

local prefix = "ardoises:cache:"
local delay  = 1 * 24 * 60 * 60 -- 1 day

return Common (function (request, cache)
  assert (type (request) == "table")
  local json  = {}
  local redis = assert (Redis.connect (Config.redis.url.host, Config.redis.url.port))
  if cache then
    json.request = Json.encode (request, {
      sort_keys = true,
    })
    local answer = redis:get (prefix .. json.request)
    if answer then
      json.answer         = Json.decode (answer)
      json.answer.headers = json.answer.headers or {}
      request.headers ["If-None-Match"    ] = json.answer.headers ["etag"         ]
                                           or json.answer.headers ["ETag"         ]
      request.headers ["If-Modified-Since"] = json.answer.headers ["last-modified"]
                                           or json.answer.headers ["Last-Modified"]
    end
  end
  local result   = {}
  request.sink   = Ltn12.sink.table (result)
  request.source = request.body  and Ltn12.source.string (request.body)
  local http = request.url:match "https://" and Https or Http
  local _, status, headers = http.request (request)
  print (Lustache:render ("{{{method}}} {{{status}}} {{{url}}}", {
    method = request.method,
    status = status,
    url    = request.url,
  }))
  result = table.concat (result)
  local hs = {}
  for key, value in pairs (headers) do
    hs [key:lower ()] = value
  end
  headers = hs
  if status == 304 then
    redis:expire (prefix .. json.request, delay)
    return json.answer
  end
  if cache then
    json.answer = Json.encode ({
      status  = status,
      headers = headers,
      body    = result,
    }, {
      sort_keys = true,
    })
    redis:set    (prefix .. json.request, json.answer)
    redis:expire (prefix .. json.request, delay)
  end
  return {
    status  = status,
    headers = headers,
    body    = result,
  }
end)
