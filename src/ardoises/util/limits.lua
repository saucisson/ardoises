#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Config    = require "ardoises.config"
local Gettime   = require "socket".gettime
local Http      = require "ardoises.jsonhttp.socket"
local Lustache  = require "lustache"
local Mime      = require "mime"
local Url       = require "net.url"

local parser = Arguments () {
  name        = "ardoises-limits",
  description = "rate limits observer",
}
parser:option "--delay" {
  description = "Delay between iterations (in seconds)",
  default     = tostring (60),
  convert     = tonumber,
}
local arguments = parser:parse ()
local last_sms  = 0

-- do
--   print "Testing twilio connectivity..."
--   for _, phone in ipairs (Config.administrator.phone) do
--     local url = Url.parse (Lustache:render ("https://api.twilio.com/2010-04-01/Accounts/{{{username}}}/Messages", Config.twilio))
--     url.query.To   = phone
--     url.query.From = Config.twilio.phone
--     url.query.Body = "Ardoises: Twilio works correctly."
--     local _, status = Http {
--       method  = "POST",
--       url     = Lustache:render ("https://api.twilio.com/2010-04-01/Accounts/{{{username}}}/Messages.json", Config.twilio),
--       headers = {
--         ["Content-type" ] = "application/x-www-form-urlencoded",
--         ["Authorization"] = "Basic " .. Mime.b64 (Config.twilio.username .. ":" .. Config.twilio.password),
--         ["User-Agent"   ] = "Ardoises",
--       },
--       body = tostring (url):match "%?(.*)$",
--     }
--     assert (status == 201, status)
--   end
--   for _ in ipairs (Config.administrator.email) do
--     assert "smtp is not implemented yet"
--   end
-- end

while true do
  print "Obtaining GitHub rate limits..."
  local start = Gettime ()
  xpcall (function ()
    local info, status = Http {
      method  = "GET",
      url     = "https://api.github.com/rate_limit",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. Config.github.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    assert (status == 200, status)
    print (Lustache:render ("  ...{{{remaining}}}.", info.resources.core))
    if  info.resources.core.remaining <= info.resources.core.limit / 10
    and Gettime () - last_sms >= 600 then
      for _, phone in ipairs (Config.administrator.phone) do
        local url = Url.parse (Lustache:render ("https://api.twilio.com/2010-04-01/Accounts/{{{username}}}/Messages", Config.twilio))
        url.query.To   = phone
        url.query.From = Config.twilio.phone
        url.query.Body = Lustache:render ("Ardoises: GitHub rate limits are low ({{{remaining}}} calls remaining). Please investigate.", info.resources.core)
        local _
        _, status = Http {
          method  = "POST",
          url     = Lustache:render ("https://api.twilio.com/2010-04-01/Accounts/{{{username}}}/Messages.json", Config.twilio),
          headers = {
            ["Content-type" ] = "application/x-www-form-urlencoded",
            ["Authorization"] = "Basic " .. Mime.b64 (Config.twilio.username .. ":" .. Config.twilio.password),
            ["User-Agent"   ] = "Ardoises",
          },
          body = tostring (url):match "%?(.*)$",
        }
        assert (status == 201, status)
      end
    end
  end, function (err)
    print (err, debug.traceback ())
  end)
  local finish = Gettime ()
  os.execute (Lustache:render ([[ sleep {{{time}}} ]], {
    time = math.max (0, arguments.delay - (finish - start)),
  }))
end
