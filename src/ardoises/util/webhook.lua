#! /usr/bin/env lua

local oldprint = print
_G.print = function (...)
  oldprint (...)
  io.stdout:flush ()
end

local Arguments = require "argparse"
local Config    = require "ardoises.config"
local Gettime   = require "socket".gettime
local Http      = require "ardoises.jsonhttp.socket-redis"
local Lustache  = require "lustache"
local Url       = require "net.url"

local parser = Arguments () {
  name        = "ardoises-webhook",
  description = "webhook installer for ardoises",
}
parser:option "--delay" {
  description = "Delay between iterations (in seconds)",
  default     = tostring (60),
  convert     = tonumber,
}
local arguments = parser:parse ()

print "Waiting for services to run..."
os.execute (Lustache:render ([[
  dockerize -wait "{{{ardoises}}}"
]], {
  ardoises = Url.build (Config.ardoises.url),
}))

while true do
  print "Setting webhooks..."
  local start = Gettime ()
  xpcall (function ()
    local repositories, status = Http {
      url     = "https://api.github.com/user/repos",
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.v3+json",
        ["Authorization"] = "token " .. Config.github.token,
        ["User-Agent"   ] = "Ardoises",
      },
    }
    assert (status == 200, status)
    for _, repository in ipairs (repositories) do
      if repository.permissions.admin then
        local hooks
        hooks, status = Http {
          url     = repository.hooks_url,
          method  = "GET",
          headers = {
            ["Accept"       ] = "application/vnd.github.v3+json",
            ["Authorization"] = "token " .. Config.github.token,
            ["User-Agent"   ] = "Ardoises",
          },
        }
        assert (status == 200, status)
        local found = false
        for _, hook in ipairs (hooks) do
          if hook.config.url == Url.build (Config.ardoises.url) .. "/webhook" then
            found = true
            break
          end
        end
        if not found then
          print (Lustache:render ("  ...setting webhook for {{{repository}}}.", {
            repository = repository.full_name,
          }))
          _, status = Http {
            url     = repository.hooks_url,
            method  = "POST",
            headers = {
              ["Accept"       ] = "application/vnd.github.v3+json",
              ["Authorization"] = "token " .. Config.github.token,
              ["User-Agent"   ] = "Ardoises",
            },
            body    = {
              name   = "web",
              config = {
                url          = Url.build (Config.ardoises.url) .. "/webhook",
                content_type = "json",
                secret       = Config.github.secret,
                insecure_ssl = "0",
              },
              events = { "*" },
              active = true,
            },
          }
          assert (status == 201 or status == 422, status)
        end
      end
    end
  end, function (err)
    print (err, debug.traceback ())
  end)
  local finish = Gettime ()
  os.execute (Lustache:render ([[ sleep {{{time}}} ]], {
    time = math.max (0, arguments.delay - (finish - start)),
  }))
end
