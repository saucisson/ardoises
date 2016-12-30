#! /usr/bin/env lua

local Arguments = require "argparse"
local Copas     = require "copas"
local Editor    = require "ardoises.editor"

local parser = Arguments () {
  name        = "ardoises-editor",
  description = "collaborative editor for ardoises",
}
parser:argument "repository" {
  description = "repository name (in 'user/repository:branch' format)",
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
local editor    = Editor.create (arguments)
Copas.addthread (function ()
  editor:start ()
end)
Copas.loop ()
