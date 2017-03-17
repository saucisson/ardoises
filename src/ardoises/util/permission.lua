#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Gettime   = require "socket".gettime
local Http      = require "ardoises.util.jsonhttp"
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
parser:option "--redis" {
  description = "Redis URL",
  default     = os.getenv "REDIS_URL",
  convert     = function (x)
    local url = assert (Url.parse (x)):normalize ()
    assert (url.host)
    return url
  end,
}
parser:option "--token" {
  description = "GitHub Token",
  default     = os.getenv "ARDOISES_TOKEN",
}
local arguments = parser:parse ()

print "Waiting for services to run..."
os.execute (Lustache:render ([[
  dockerize -wait "{{{redis}}}"
]], {
  redis = os.getenv "REDIS_URL",
}))

local pattern   = "ardoises:info:{{{what}}}"
local redis     = assert (Redis.connect (arguments.redis.host, arguments.redis.port))

while true do
  print "Obtaining permissions..."
  local start = Gettime ()
  xpcall (function ()
    local repositories, collaborators, status
    repositories, status = Http {
      url     = "https://api.github.com/user/repos",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. arguments.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    assert (status == 200, status)
    for _, repository in ipairs (repositories) do
      print (Lustache:render ("  ...updating permissions for {{{repository}}}.", {
        repository = repository.full_name,
      }))
      local key = Lustache:render (pattern, { what = repository.full_name })
      redis:setnx (key, Json.encode (repository))
      collaborators, status = Http {
        url     = repository.url .. "/collaborators",
        method  = "GET",
        headers = {
          ["Accept"       ] = "application/vnd.github.korra-preview+json",
          ["Authorization"] = "token " .. arguments.token,
          ["User-Agent"   ] = "Ardoises",
        },
      }
      assert (status == 200, status)
      for _, collaborator in ipairs (collaborators) do
        local user_key = Lustache:render (pattern, { what = collaborator.login })
        redis:watch (user_key)
        local user = redis:get (user_key)
        user = user and Json.decode (user)
        redis:multi ()
        if user then
          user.ardoises = user.ardoises or {}
          user.ardoises [repository.full_name] = collaborator.permissions
          redis:set (user_key, user)
        end
        redis:exec ()
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
