#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Config    = require "ardoises.config"
local Http      = require "ardoises.jsonhttp.socket-redis"
local Json      = require "rapidjson"
local Keys      = require 'ardoises.server.keys'
local Lustache  = require "lustache"
local Redis     = require "redis"
local Url       = require "net.url"

local parser = Arguments () {
  name        = "ardoises-populate",
  description = "populate data in ardoises",
}
local _ = parser:parse ()

print "Waiting for services to run..."
os.execute (Lustache:render ([[
  dockerize -wait "{{{redis}}}" \
            -wait "{{{ardoises}}}"
]], {
  redis    = Url.build (Config.redis.url),
  ardoises = Url.build (Config.ardoises.url),
}))

local redis  = assert (Redis.connect (Config.redis.url.host, Config.redis.url.port))

print "Cleaning data..."
xpcall (function ()
  local cursor = 0
  repeat
    local res = redis:scan (cursor, {
      match = Keys.repository {
        owner = { login = "*" },
        name  = "*",
      },
      count = 100,
    })
    if not res then
      break
    end
    cursor = res [1]
    local keys = res [2]
    for _, key in ipairs (keys) do
      local repository = redis:get (key)
      repository = Json.decode (repository)
      print (Lustache:render ("  ...populating {{{repository}}}.", {
        repository = repository.full_name,
      }))
      local _, status = Http {
        url = Url.build {
          scheme = "https",
          host   = Config.ardoises.url.host,
          port   = Config.ardoises.url.port,
          path   = "/webhook",
        },
        method    = "POST",
        signature = "X-Hub-Signature",
        headers   = {
          ["Accept"       ] = "application/vnd.github.v3+json",
          ["Authorization"] = "token " .. Config.github.token,
          ["User-Agent"   ] = "Ardoises",
        },
        body = {
          repository = repository,
        },
      }
      assert (status == 200, status)
    end
  until cursor == "0"
end, function (err)
  print (err, debug.traceback ())
end)

print "Populating data..."
xpcall (function ()
  local repositories, status = Http {
    url     = "https://api.github.com/user/repos",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. Config.github.token,
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
        host   = Config.ardoises.url.host,
        port   = Config.ardoises.url.port,
        path   = "/webhook",
      },
      method    = "POST",
      signature = "X-Hub-Signature",
      headers   = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. Config.github.token,
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
