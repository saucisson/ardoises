#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Config   = require "ardoises.config"
local Http     = require "ardoises.jsonhttp.socket"
local Json     = require "rapidjson"
local Jwt      = require "jwt"
local Lustache = require "lustache"
local Redis    = require "redis"
local Setenv   = require "posix.stdlib".setenv
local Socket   = require "socket"
local Url      = require "net.url"

print "Waiting for services to run..."
os.execute (Lustache:render ([[
  dockerize -wait "{{{docker}}}" \
            -wait "{{{redis}}}"
]], {
  docker = os.getenv "DOCKER_URL",
  redis  = os.getenv "REDIS_URL",
}))

-- FIXME:  nginx resolver does not seem to work within docker-compose,
-- so we convert all service hostnames to IPs before launching the server.
for _, address in ipairs { "DOCKER_URL", "REDIS_URL" } do
  local parsed = assert (Url.parse (os.getenv (address)))
  parsed.host  = assert (Socket.dns.toip (parsed.host))
  Setenv (address, Url.build (parsed))
end

print "Creating data..."
do
  local redis = assert (Redis.connect (Config.redis.host, Config.redis.port))
  local user, status = Http {
    url     = "https://api.github.com/user",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. Config.application.token,
      ["User-Agent"   ] = "Ardoises",
    },
  }
  assert (status == 200, status)
  local key = Config.patterns.user (user)
  user.tokens = {
    github   = Config.application.token,
    ardoises = Jwt.encode ({
      login = user.login,
    }, {
      alg  = "HS256",
      keys = { private = Config.application.secret },
    }),
  }
  redis:setnx (key, Json.encode (user))
end

print "Starting reloader..."
assert (os.execute [=[
# https://miteshshah.github.io/linux/nginx/auto-reload-nginx/
while true
do
  inotifywait \
    --recursive \
    --event create \
    --event modify \
    --event delete \
    --event move \
    /usr/share/lua/5.1/ardoises
  if $(nginx -t)
  then
    nginx -s reload
  fi
done &
]=])

print "Starting server..."
assert (os.execute [[
  nginx \
    -p /usr/local/openresty/nginx/ \
    -c /etc/nginx/nginx.conf
]])
