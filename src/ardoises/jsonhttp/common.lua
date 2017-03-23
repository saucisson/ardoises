local Json = require "rapidjson"
local Url  = require "net.url"

return function (what)
  return function (options)
    assert (type (options) == "table")
    local request = {}
    local answer  = {}
    local url     = Url.parse (options.url):normalize ()
    for name, value in pairs (options.query or {}) do
      url.query [name] = value
    end
    request.url    = tostring (url)
    request.method = options.method or "GET"
    request.body   = options.body   and Json.encode (options.body, {
      sort_keys = true,
    })
    request.headers = {}
    for name, header in pairs (options.headers or  {}) do
      request.headers [name] = header
    end
    request.headers ["Content-length"] = request.body and #request.body
    request.headers ["Content-type"  ] = request.body and "application/json"
    request.headers ["Accept"        ] = request.headers ["Accept"] or "application/json"
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
      if result.headers ["Link"] and result.status == 304 then
        cache = true
      end
      for link in (result.headers ["Link"] or ""):gmatch "[^,]+" do
        request.url = link:match [[<([^>]+)>;%s*rel="next"]] or request.url
      end
    until not request.url
    return answer.body, answer.status, answer.headers
  end
end
