#! /usr/bin/env lua

local Et     = require "etlua"
local Http   = require "ardoises.jsonhttp".default
local Setenv = require "posix.stdlib".setenv
local Socket = require "socket"
local Url    = require "socket.url"

local mode = os.getenv "ARDOISES_MODE" or "development"

print "Waiting for services to run..."
os.execute (Et.render ([[
  dockerize -wait "<%- docker %>" \
            -wait "<%- postgres %>" \
            -wait "<%- redis %>"
]], {
  docker   = os.getenv "DOCKER_PORT",
  postgres = os.getenv "POSTGRES_PORT",
  redis    = os.getenv "REDIS_PORT",
}))

print "Getting the docker image name..."
local info, status = Http {
  method = "GET",
  url    = Et.render ("<%- docker %>/containers/<%- id %>/json", {
    docker = os.getenv "DOCKER_PORT":gsub ("^tcp://", "http://"),
    id     = os.getenv "HOSTNAME",
  }),
}
assert (status == 200, status)
Setenv ("ARDOISES_IMAGE", info.Config.Image)

-- FIXME:  nginx resolver does not seem to work within docker-compose or
-- docker-cloud, so we convert all service hostnames to ips before
-- launching the server.
for _, address in ipairs { "POSTGRES_PORT", "REDIS_PORT" } do
  local parsed = assert (Url.parse (os.getenv (address)))
  parsed.host  = assert (Socket.dns.toip (parsed.host))
  Setenv (address, Url.build (parsed))
end

print "Applying database migrations..."
assert (os.execute ("lapis migrate " .. mode))

print "Starting server..."
assert (os.execute ("lapis server "  .. mode))
