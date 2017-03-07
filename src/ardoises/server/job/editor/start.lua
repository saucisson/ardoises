local Config  = require "lapis.config".get ()
local Et      = require "etlua"
local Http    = require "ardoises.jsonhttp".resty
local Model   = require "ardoises.server.model"
local gettime = require "socket".gettime

local Start = {}

function Start.perform (job)
  local editor = Model.editors:create {
    repository = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", job.data),
    starting   = true,
  }
  if not editor then
    return
  end
  pcall (function ()
    local status, service, info, _
    service, status = Http {
      url    = "docker:///containers/create",
      method = "POST",
      body   = {
        Entrypoint   = "ardoises-editor",
        Cmd          = {
          Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", job.data),
          Config.application.token,
        },
        Image        = Config.application.image,
        ExposedPorts = {
          ["8080/tcp"] = {},
        },
        HostConfig   = {
          PublishAllPorts = true,
        },
      },
    }
    assert (status == 201, status)
    editor:update {
      docker = service.Id,
    }
    _, status = Http {
      method = "POST",
      url    = Et.render ("docker:///containers/<%- id %>/start", {
        id = service.Id,
      }),
    }
    assert (status == 204, status)
    local start = gettime ()
    while gettime () - start <= 120 do
      job:heartbeat ()
      info, status = Http {
        method = "GET",
        url    = Et.render ("docker:///containers/<%- id %>/json", {
          id = service.Id,
        }),
      }
      assert (status == 200, status)
      if info.State.Running then
        local data = ((info.NetworkSettings.Ports ["8080/tcp"] or {}) [1] or {})
        if data.HostPort then
          editor:update {
            url = Et.render ("ws://<%- host %>:<%- port %>", {
              host = data.HostIp,
              port = data.HostPort,
            }),
          }
          return
        end
      elseif info.State.Dead then
        break
      else
        _G.ngx.sleep (1)
      end
    end
  end)
  editor:update {
    starting = false,
  }
  return true
end

return Start
