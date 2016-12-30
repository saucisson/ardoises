local Json = require "cjson"
local Util = require "lapis.util"

local JsonHttp = {}

function JsonHttp.resty (options)
  assert (type (options) == "table")
  local Httpr = require "resty.http"
  options.ssl_verify = false
  options.method     = options.method  or "GET"
  options.body       = options.body    and Json.encode (options.body)
  options.headers    = options.headers or {}
  local query        = options.query   and {}
  if query then
    for k, v in pairs (options.query) do
      query [#query+1] = Util.encode (k) .. "=" .. Util.encode (v)
    end
  end
  options.query      = query and table.concat (query, "&")
  options.headers ["Content-length"] = options.body and #options.body
  options.headers ["Content-type"  ] = options.body and "application/json"
  options.headers ["Accept"        ] = options.headers ["Accept"] or "application/json"
  local client = Httpr.new ()
  client:set_timeout ((options.timeout or 5) * 1000) -- milliseconds
  local result = assert (client:request_uri (options.url, options))
  if result.body then
    local ok, json = pcall (Json.decode, result.body)
    if ok then
      result.body = json
    end
  end
  return result.body, result.status, result.headers
end

function JsonHttp.copas (options)
  assert (type (options) == "table")
  local Httpc = require "copas.http"
  local Ltn12 = require "ltn12"
  local result = {}
  options.sink    = Ltn12.sink.table (result)
  options.body    = options.body  and Json.encode (options.body)
  options.source  = options.body  and Ltn12.source.string (options.body)
  local query     = options.query and {}
  if query then
    for k, v in pairs (options.query) do
      query [#query+1] = Util.encode (k) .. "=" .. Util.encode (v)
    end
  end
  options.query   = query and table.concat (query, "&")
  options.headers = options.headers or {}
  options.headers ["Content-length"] = options.body and #options.body or 0
  options.headers ["Content-type"  ] = options.body and "application/json"
  options.headers ["Accept"        ] = options.headers ["Accept"] or "application/json"
  local _, status, headers = Httpc.request (options)
  result = #result ~= 0
       and Json.decode (table.concat (result))
  return result, status, headers
end

function JsonHttp.default (options)
  assert (type (options) == "table")
  local Httpn = require "socket.http"
  local Https = require "ssl.https"
  local Ltn12 = require "ltn12"
  local result = {}
  options.sink    = Ltn12.sink.table (result)
  options.body    = options.body  and Json.encode (options.body)
  options.source  = options.body  and Ltn12.source.string (options.body)
  local query     = options.query and {}
  if query then
    for k, v in pairs (options.query) do
      query [#query+1] = Util.encode (k) .. "=" .. Util.encode (v)
    end
  end
  options.query   = query and table.concat (query, "&")
  options.headers = options.headers or {}
  options.headers ["Content-length"] = options.body and #options.body or 0
  options.headers ["Content-type"  ] = options.body and "application/json"
  options.headers ["Accept"        ] = options.headers ["Accept"] or "application/json"
  local http = options.url:match "https://" and Https or Httpn
  local _, status, headers = http.request (options)
  result = #result ~= 0
       and Json.decode (table.concat (result))
  return result, status, headers
end

return JsonHttp
