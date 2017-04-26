#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Config    = require "ardoises.config"
local Gettime   = require "socket".gettime
local Http      = require "ardoises.jsonhttp.socket-redis"
local Json      = require "rapidjson"
local Lustache  = require "lustache"
local Redis     = require "redis"
local Url       = require "net.url"

local parser = Arguments () {
  name        = "ardoises-clean",
  description = "docker cleaner for ardoises",
}
parser:option "--delay" {
  description = "Delay between iterations (in seconds)",
  default     = "60",
  convert     = tonumber,
}
local arguments = parser:parse ()

print "Waiting for services to run..."
os.execute (Lustache:render ([[
  dockerize -wait "{{{redis}}}" \
            -wait "{{{docker}}}"
]], {
  redis  = Config.redis.url,
  docker = Config.docker.url,
}))
local redis = assert (Redis.connect (Config.redis.host, Config.redis.port))

while true do
  print "Answering to invitations..."
  local start = Gettime ()
  xpcall (function ()
    local invitations, status = Http {
      url     = "https://api.github.com/user/repository_invitations",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.swamp-thing-preview+json",
        ["Authorization"] = "token " .. Config.application.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    assert (status == 200, status)
    for _, invitation in ipairs (invitations) do
      print (Lustache:render ("  ...accepting invitation for {{{repository}}}.", {
        repository = invitation.repository.full_name,
      }))
      _, status = Http {
        url     = Lustache:render ("https://api.github.com/user/repository_invitations/{{{id}}}", invitation),
        method  = "PATCH",
        headers = {
          ["Accept"       ] = "application/vnd.github.swamp-thing-preview+json",
          ["Authorization"] = "token " .. Config.application.token,
          ["User-Agent"   ] = "Ardoises",
        },
      }
      assert (status == 204, status)
      local user = redis:get (Config.patterns.user (invitation.repository.owner))
      assert (user)
      user = Json.decode (user)
      assert (user)
      _, status = Http {
        url     = invitation.repository.hooks_url,
        method  = "POST",
        headers = {
          ["Accept"       ] = "application/vnd.github.v3+json",
          ["Authorization"] = "token " .. user.tokens.github,
          ["User-Agent"   ] = "Ardoises",
        },
        body    = {
          name   = "web",
          config = {
            url          = Config.ardoises.url .. "/webhook",
            content_type = "json",
            secret       = Config.application.secret,
            insecure_ssl = "0",
          },
          events = { "*" },
          active = true,
        },
      }
      assert (status == 201 or status == 422, status)
    end
  end, function (err)
    print (err, debug.traceback ())
  end)
  local finish = Gettime ()
  os.execute (Lustache:render ([[ sleep {{{time}}} ]], {
    time = math.max (0, arguments.delay - (finish - start)),
  }))
end
