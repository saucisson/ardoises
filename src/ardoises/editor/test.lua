#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local setenv = require "posix.stdlib".setenv
setenv ("HOSTNAME", "localhost")

local Arguments = require "argparse"
local Basexx    = require "basexx"
local Client    = require "ardoises.client"
local Config    = require "ardoises.config"
local Copas     = require "copas"
local Editor    = require "ardoises.editor"
local Lustache  = require "lustache"
local Patterns  = require "ardoises.patterns"
local Url       = require "net.url"

local parser = Arguments () {
  name        = "ardoises-instance",
  description = "collaborative editor instance for ardoises",
}
parser:option "--token" {
  description = "access token",
  default     = Config.test.user.token,
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
  default     = Url.build (Config.ardoises.url),
  convert     = function (x)
    local url = Url.parse (x)
    assert (url and url.scheme and url.host)
    return url
  end,
}
parser:option "--require" {
  description = "module to require",
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
    token        = Config.github.token,
    port         = arguments.port,
    application  = "Ardoises",
    nopush       = true,
  }
  editor:start ()
  repeat
    Copas.sleep (1)
  until editor.port ~= 0
  local filename   = os.tmpname ()
  local identifier = "ardoises-" .. client.user.login .. "-" .. tostring (editor.port)
  local domain     = Basexx.to_base32 (identifier):lower ():match "([^=]+)"
  assert (#domain < 64)
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
  if arguments.require then
    io.write ("Loading " .. arguments.require .. "...")
    io.flush ()
    local ok, err = editor:require (arguments.require .. "@-/-:" .. arguments.port)
    if ok then
      print (" success.")
    else
      print (" failure: " .. err)
    end
  end
end)
Copas.loop ()
