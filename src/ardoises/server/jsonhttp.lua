local Http     = require "ardoises.jsonhttp"
local Json     = require "rapidjson"
local Httph    = require "resty.http"
local Lustache = require "lustache"
local Redis    = require "resty.redis"
local Url      = require "net.url"

local prefix = "ardoises:cache:"
local delay  = 1 * 24 * 60 * 60 -- 1 day
local Config = {
  redis = assert (Url.parse (os.getenv "REDIS_URL"))
}

return Http (function (request, cache)
  assert (type (request) == "table")
  local json  = {}
  local redis = Redis:new ()
  assert (redis:connect (Config.redis.host, Config.redis.port))
  request.ssl_verify = false
  if cache then
    json.request = Json.encode (request, {
      sort_keys = true,
    })
    local answer = redis:get (prefix .. json.request)
    if answer ~= _G.ngx.null then
      json.answer = Json.decode (answer)
      request.headers ["If-None-Match"    ] = json.answer.headers ["etag"         ]
                                           or json.answer.headers ["ETag"         ]
      request.headers ["If-Modified-Since"] = json.answer.headers ["last-modified"]
                                           or json.answer.headers ["Last-Modified"]
    end
  end
  local client = Httph.new ()
  client:set_timeout (1000) -- milliseconds
  local result = assert (client:request_uri (request.url, request))
  print (Lustache:render ("{{{method}}} {{{status}}} {{{url}}}", {
    method = request.method,
    status = result.status,
    url    = request.url,
  }))
  if result.status == 304 then
    redis:expire (prefix .. json.request, delay)
    return json.answer
  end
  if cache then
    json.answer = Json.encode ({
      status  = result.status,
      headers = result.headers,
      body    = result.body,
    }, {
      sort_keys = true,
    })
    redis:set    (prefix .. json.request, json.answer)
    redis:expire (prefix .. json.request, delay)
  end
  redis:set_keepalive (10 * 1000, 100)
  return result
end)
