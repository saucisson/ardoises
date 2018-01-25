#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local oldexecute = os.execute
_G.os.execute = function (...)
  print (...)
  return oldexecute (...)
end

local Arguments = require "argparse"
local Copas     = require "copas"
local Editor    = require "ardoises.editor"
local Patterns  = require "ardoises.patterns"
local Url       = require "net.url"

local parser = Arguments () {
  name        = "ardoises-editor",
  description = "collaborative editor for ardoises",
}
parser:option "--branch" {
  description = "branch to edit (in 'user/repository:branch' format)",
  default     = os.getenv "ARDOISES_BRANCH",
  convert     = function (x)
    return assert (Patterns.branch:match (x))
  end,
}
parser:option "--token" {
  description = "access token",
  default     = os.getenv "ARDOISES_TOKEN",
}
parser:option "--application" {
  description = "application name",
  default     = "Ardoises"
}
parser:option "--timeout" {
  description = "timeout (in second)",
  convert     = tonumber,
  default     = tostring (60), -- seconds
}
parser:option "--port" {
  description = "port",
  convert     = tonumber,
  default     = tostring (8080),
}
parser:option "--ardoises" {
  description = "URL of the ardoises server",
  default     = os.getenv "ARDOISES_URL",
  convert     = function (x)
    local url = Url.parse (x)
    assert (url and url.scheme and url.host)
    return url
  end,
}

local arguments = parser:parse ()
Copas.addthread (function ()
  local editor = Editor (arguments)
  editor:start ()
end)
Copas.loop ()
