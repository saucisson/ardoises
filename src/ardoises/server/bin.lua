#! /usr/bin/env lua

local Http     = require "ardoises.util.jsonhttp"
local Lustache = require "lustache"
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

print "Getting the docker image name..."
local info, status = Http {
  method = "GET",
  url    = Lustache:render ("{{{docker}}}/containers/{{{id}}}/json", {
    docker = os.getenv "DOCKER_URL":gsub ("^tcp://", "http://"),
    id     = os.getenv "HOSTNAME",
  }),
}
assert (status == 200, status)
Setenv ("ARDOISES_IMAGE", info.Config.Image)

-- FIXME:  nginx resolver does not seem to work within docker-compose,
-- so we convert all service hostnames to IPs before launching the server.
for _, address in ipairs { "DOCKER_URL", "REDIS_URL" } do
  local parsed = assert (Url.parse (os.getenv (address)))
  parsed.host  = assert (Socket.dns.toip (parsed.host))
  Setenv (address, Url.build (parsed))
end

print "Starting server..."
assert (os.execute ([[
  nginx \
    -p /usr/local/openresty/nginx/ \
    -c /etc/nginx/nginx.conf
]]))
