#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Config    = require "ardoises.server.config"
local Gettime   = require "socket".gettime
local Http      = require "ardoises.jsonhttp.socket-redis"
local Json      = require "rapidjson"
local Lustache  = require "lustache"
local Redis     = require "redis"

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

local redis  = assert (Redis.connect (Config.redis.host, Config.redis.port))
local cursor = "0"
local keys

while true do
  print "Cleaning..."
  local start = Gettime ()
  xpcall (function ()
    cursor, keys = unpack (redis:scan (cursor, {
        match = Config.patterns.repository {
          name  = "*",
          owner = { login = "*" },
        },
        count = 100,
    }))
    for _, key in ipairs (keys) do
      redis:watch (key)
      local repository = redis:get (key)
      repository = repository and Json.decode (repository)
      redis:multi ()
      if repository and repository.docker_url then
        local info, status = Http {
          method = "GET",
          url    = repository.docker_url .. "/json",
        }
        if status == 200 and not info.State.Running then
          print (Lustache:render ("  ...cleaning docker for {{{repository}}}.", {
            repository = repository.full_name,
          }))
          _, status = Http {
            method = "DELETE",
            url    = repository.docker_url,
            query  = {
              v     = true,
              force = true,
            },
          }
          if status == 204 or status == 404 then
            repository.docker_url = nil
            redis:set (key, Json.encode (repository))
          end
        elseif status == 404 then
          repository.docker_url = nil
          redis:set (key, Json.encode (repository))
        end
      end
      assert (redis:exec ())
    end
  end, function (err)
    print (err, debug.traceback ())
    cursor = "0"
  end)
  local finish = Gettime ()
  os.execute (Lustache:render ([[ sleep {{{time}}} ]], {
    time = math.max (0, arguments.delay - (finish - start)),
  }))
end
