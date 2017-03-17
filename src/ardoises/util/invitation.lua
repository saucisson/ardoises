#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Gettime   = require "socket".gettime
local Http      = require "ardoises.util.jsonhttp"
local Lustache  = require "lustache"

local parser = Arguments () {
  name        = "ardoises-clean",
  description = "docker cleaner for ardoises",
}
parser:option "--delay" {
  description = "Delay between iterations (in seconds)",
  default     = "60",
  convert     = tonumber,
}
parser:option "--token" {
  description = "GitHub Token",
  default     = os.getenv "ARDOISES_TOKEN",
}
local arguments = parser:parse ()

while true do
  print "Answering to invitations..."
  local start = Gettime ()
  xpcall (function ()
    local invitations, status = Http {
      url     = "https://api.github.com/user/repository_invitations",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.swamp-thing-preview+json",
        ["Authorization"] = "token " .. arguments.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    if status ~= 200 then
      return nil
    end
    for _, invitation in ipairs (invitations) do
      print (Lustache:render ("  ...accepting invitation for {{{repository}}}.", {
        repository = invitation.repository.full_name,
      }))
      Http {
        url     = Lustache:render ("https://api.github.com/user/repository_invitations/{{{id}}}", invitation),
        method  = "PATCH",
        headers = {
          ["Accept"       ] = "application/vnd.github.swamp-thing-preview+json",
          ["Authorization"] = "token " .. arguments.token,
          ["User-Agent"   ] = "Ardoises",
        },
      }
    end
  end, function (err)
    print (err, debug.traceback ())
  end)
  local finish = Gettime ()
  os.execute (Lustache:render ([[ sleep {{{time}}} ]], {
    time = math.max (0, arguments.delay - (finish - start)),
  }))
end
