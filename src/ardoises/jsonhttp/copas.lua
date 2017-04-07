local Common = require "ardoises.jsonhttp.common"
local Http   = require "copas.http"
local Ltn12  = require "ltn12"

return Common (function (request)
  assert (type (request) == "table")
  local result = {}
  request.sink   = Ltn12.sink.table (result)
  request.source = request.body and Ltn12.source.string (request.body)
  local _, status, headers = Http.request (request)
  return {
    status  = status,
    headers = headers,
    body    = table.concat (result),
  }
end)
