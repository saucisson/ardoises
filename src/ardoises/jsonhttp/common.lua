local Json = require "rapidjson"
local Url  = require "net.url"

-- http://25thandclement.com/~william/projects/luaossl.pdf
local function tohex (b)
  local x = ""
  for i = 1, #b do
    x = x .. string.format ("%.2x", string.byte (b, i))
  end
  return x
end

return function (what)
  return function (options)
    assert (type (options) == "table")
    local request = {}
    local answer  = {}
    local url     = Url.parse (options.url):normalize ()
    for name, value in pairs (options.query or {}) do
      url.query [name] = value
    end
    request.timeout = options.timeout
    request.url     = tostring (url)
    request.method  = options.method or "GET"
    request.headers = {}
    for name, header in pairs (options.headers or  {}) do
      request.headers [name] = header
    end
    request.headers ["Content-type"  ] = request.headers ["Content-type"] or "application/json"
    request.headers ["Accept"        ] = request.headers ["Accept"      ] or "application/json"
    request.body = options.body
    if request.headers ["Content-type"]:match "json" then
      request.body = request.body and Json.encode (request.body, {
        sort_keys = true,
      })
    end
    request.headers ["Content-length"] = request.body and #request.body
    if options.signature then
      local Config = require "ardoises.config"
      local Hmac   = require "openssl.hmac"
      local hmac   = Hmac.new (Config.application.secret)
      request.headers [options.signature] = "sha1=" .. tohex (hmac:final (request.body))
    end
    local cache = request.method == "GET"
               or options.cache
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
      if  result.headers
      and result.headers ["Link"]
      and result.status == 304 then
        cache = true
      end
      for link in ((result.headers or {}) ["Link"] or ""):gmatch "[^,]+" do
        request.url = link:match [[<([^>]+)>;%s*rel="next"]] or request.url
      end
    until not request.url
    return answer.body, answer.status, answer.headers
  end
end
