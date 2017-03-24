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

print "Cleaning redis cache..."
repeat
  cursor, keys = unpack (redis:scan (cursor, {
    match = "ardoises:cache:*",
    count = 100,
  }))
  for _, key in ipairs (keys) do
    redis:del (key)
  end
until cursor == "0"

cursor = "0"
while true do
  print "Cleaning..."
  local start = Gettime ()
  xpcall (function ()
    cursor, keys = unpack (redis:scan (cursor, {
        match = Config.patterns.editor ({
          owner = { login = "*" },
          name  = "*",
        }, "*"),
        count = 100,
    }))
    for _, key in ipairs (keys) do
      local editor = redis:get (key)
      editor = editor and Json.decode (editor)
      if editor
      and (editor.started_at
        or not editor.created_at
        or Gettime () - editor.created_at > 120) then
        local docker_url = Lustache:render ("http://{{{host}}}:{{{port}}}/containers/{{{id}}}", {
          host = Config.docker.host,
          port = Config.docker.port,
          id   = editor.docker_id,
        })
        local info, status = Http {
          method = "GET",
          url    = docker_url .. "/json",
        }
        if status == 200 and not info.State.Running then
          print (Lustache:render ("  ...cleaning docker container {{{docker_id}}}.", editor))
          Http {
            method = "DELETE",
            url    = docker_url,
            query  = {
              v     = true,
              force = true,
            },
          }
          redis:del (key)
        elseif status == 404 then
          redis:del (key)
        end
      end
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
