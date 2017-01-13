#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Copas     = require "copas"
local Editor    = require "ardoises.editor"
local Http      = require "ardoises.jsonhttp".default
local Mime      = require "mime"
local Patterns  = require "ardoises.patterns"

local parser = Arguments () {
  name        = "ardoises-editor",
  description = "collaborative editor for ardoises",
}
parser:argument "branch" {
  description = "branch to edit (in 'user/repository:branch' format)",
  convert     = function (x)
    return assert (Patterns.branch:match (x))
  end,
}
parser:argument "token" {
  description = "access token",
}
parser:option "--application" {
  description = "application name",
  default     = "Ardoises"
}
parser:option "--timeout" {
  description = "timeout (in second)",
  convert     = tonumber,
  default     = 60, -- seconds
}
parser:option "--port" {
  description = "port",
  convert     = tonumber,
  default     = 8080,
}

local arguments = parser:parse ()
Copas.addthread (function ()
  local editor = Editor (arguments)
  editor:start ()
end)
Copas.loop ()

-- Force deletion of service, as docker cloud seems buggy.
if os.getenv "DOCKERCLOUD_SERVICE_API_URL" then
  Http {
    url     = os.getenv "DOCKERCLOUD_SERVICE_API_URL",
    method  = "DELETE",
    headers = {
      ["Authorization"] = "Basic " .. Mime.b64 (os.getenv "DOCKER_USER" .. ":" .. os.getenv "DOCKER_SECRET"),
    },
  }
end
