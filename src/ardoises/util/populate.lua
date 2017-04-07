#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Config    = require "ardoises.server.config"
local Http      = require "ardoises.jsonhttp.socket-redis"
local Lustache  = require "lustache"
local Url       = require "net.url"

local parser = Arguments () {
  name        = "ardoises-populate",
  description = "populate data in ardoises",
}
local _ = parser:parse ()

print "Waiting for services to run..."
os.execute (Lustache:render ([[
  dockerize -wait "{{{ardoises}}}"
]], {
  ardoises = Config.ardoises.url,
}))

print "Populating data..."
xpcall (function ()
  local repositories, status = Http {
    url     = "https://api.github.com/user/repos",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. Config.application.token,
      ["User-Agent"   ] = "Ardoises",
    },
  }
  assert (status == 200, status)
  for _, repository in ipairs (repositories) do
    print (Lustache:render ("  ...populating {{{repository}}}.", {
      repository = repository.full_name,
    }))
    _, status = Http {
      url = Url.build {
        scheme = "https",
        host   = Config.ardoises.host,
        port   = Config.ardoises.port,
        path   = "/webhook",
      },
      method    = "POST",
      signature = "X-Hub-Signature",
      headers   = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. Config.application.token,
        ["User-Agent"   ] = "Ardoises",
      },
      body = {
        repository = repository,
      },
    }
    assert (status == 200, status)
  end
end, function (err)
  print (err, debug.traceback ())
end)
