local Common   = require "ardoises.jsonhttp.common"
local Http     = require "socket.http"
local Https    = require "ssl.https"
local Ltn12    = require "ltn12"
local Lustache = require "lustache"

return Common (function (request)
  assert (type (request) == "table")
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
  return {
    status  = status,
    headers = headers,
    body    = result,
  }
end)
