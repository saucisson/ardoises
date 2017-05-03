#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Basexx    = require "basexx"
local Client    = require "ardoises.client"
local Copas     = require "copas"
local Editor    = require "ardoises.editor"
local Lustache  = require "lustache"
local Patterns  = require "ardoises.patterns"
local Setenv    = require "posix.stdlib".setenv
local Url       = require "net.url"

for line in io.lines ".environment" do
  local key, value = line:match "^([%w_]+)=(.*)$"
  if key and value then
    Setenv (key, value)
  end
end

local parser = Arguments () {
  name        = "ardoises-instance",
  description = "collaborative editor instance for ardoises",
}
parser:option "--token" {
  description = "access token",
  default     = os.getenv "USER_TOKEN",
}
parser:option "--timeout" {
  description = "timeout (in second)",
  convert     = tonumber,
  default     = tostring (600), -- seconds
}
parser:option "--port" {
  description = "port",
  convert     = tonumber,
  default     = tostring (0),
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
  local client = Client {
    server = Url.build (arguments.ardoises),
    token  = arguments.token,
  }
  local editor = Editor {
    ardoises     = arguments.ardoises,
    branch       = Patterns.branch:match ("-/-:" .. arguments.port),
    timeout      = 600,
    token        = client.user.tokens.github,
    port         = arguments.port,
    application  = "Ardoises",
    nopush       = true,
  }
  editor:start ()
  repeat
    Copas.sleep (1)
  until editor.port ~= 0
  local filename = os.tmpname ()
  local domain   = Basexx.to_crockford ("ardoises-" .. client.user.login):lower ()
  os.execute (Lustache:render ([[
    lt --subdomain "{{{domain}}}" --port "{{{port}}}" > "{{{filename}}}" &
  ]], {
    domain   = domain,
    port     = editor.port,
    filename = filename,
  }))
  repeat
    local file     = io.open (filename, "r")
    local contents = file:read "*a"
    file:close ()
  until contents:match "your url is"
  print (Lustache:render ("Your local repository is usable at: https://{{{host}}}:{{{port}}}/views/-/-/{{{domain}}}", {
    host   = arguments.ardoises.host,
    port   = arguments.ardoises.port,
    domain = domain,
  }))
end)
Copas.loop ()
