#! /usr/bin/env lua

local Et     = require "etlua"
local Http   = require "ardoises.jsonhttp".default
local Mime   = require "mime"
local Posix  = require "posix"
local Setenv = require "posix.stdlib".setenv
local Socket = require "socket"
local Stat   = require "posix.sys.stat".stat
local Url    = require "socket.url"

local mode = os.getenv "ARDOISES_MODE" or "development"

if os.getenv "DOCKERCLOUD_SERVICE_API_URL" then
  print "Getting the docker image name..."
  local info, status = Http {
    url     = assert (os.getenv "DOCKERCLOUD_SERVICE_API_URL"),
    method  = "GET",
    headers = {
      ["Authorization"] = "Basic " .. Mime.b64 (assert (os.getenv "DOCKER_USER") .. ":" .. assert (os.getenv "DOCKER_SECRET")),
    },
  }
  assert (status == 200, status)
  Setenv ("ARDOISES_IMAGE", info.image_name)
else
  assert (Stat "/var/run/docker.sock")
  print "Fixing permissions on docker socket..."
  assert (Posix.chmod ("/var/run/docker.sock", "ugo+w"))

  print "Getting the docker image name..."
  local info, status = Http {
    method = "GET",
    url    = Et.render ("docker:///containers/<%- id %>/json", {
      id = os.getenv "HOSTNAME" or "fc608fcb1d3e",
    }),
  }
  assert (status == 200, status)
  Setenv ("ARDOISES_IMAGE", info.Config.Image)
end

-- FIXME:  nginx resolver does not seem to work within docker-compose or
-- docker-cloud, so we convert all service hostnames to ips before
-- launching the server.
for _, address in ipairs { "POSTGRES_PORT", "REDIS_PORT" } do
  local parsed = assert (Url.parse (os.getenv (address)))
  parsed.host  = assert (Socket.dns.toip (parsed.host))
  Setenv (address, Url.build (parsed))
end

print "Waiting for services to run..."
for _, address in ipairs { "POSTGRES_PORT", "REDIS_PORT" } do
  local parsed = assert (Url.parse (os.getenv (address)))
  local socket = Socket.tcp ()
  local i      = 0
  while not socket:connect (parsed.host, parsed.port) do
    if i > 30 then
      error (os.getenv (address) .. " is not reachable.")
    end
    os.execute [[ sleep 1 ]]
    i = i+1
  end
end

print "Applying database migrations..."
assert (os.execute ("lapis migrate " .. mode))

print "Starting server..."
assert (os.execute ("lapis server "  .. mode))
