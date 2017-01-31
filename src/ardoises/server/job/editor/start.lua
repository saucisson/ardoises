local Config  = require "lapis.config".get ()
local Et      = require "etlua"
local Http    = require "ardoises.jsonhttp".resty
local Json    = require "rapidjson"
local Mime    = require "mime"
local Model   = require "ardoises.server.model"
local gettime = require "socket".gettime

local Start = {}

if os.getenv "DOCKERCLOUD_SERVICE_API_URL" then
  function Start.perform (job)
    local editor = Model.editors:create {
      repository = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", job.data),
      starting   = true,
    }
    if not editor then
      return
    end
    local url     = "https://cloud.docker.com"
    local api     = url .. "/api/app/v1/ardoises"
    local headers = {
      ["Authorization"] = "Basic " .. Mime.b64 (Config.docker.username .. ":" .. Config.docker.api_key),
    }
    local arguments = Et.render ([["<%- repository %>" "<%- token %>"]], {
      repository  = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", job.data),
      token       = job.data.token,
    })
    pcall (function ()
      -- Create service:
      local service, service_status = Http {
        url     = api .. "/service/",
        method  = "POST",
        headers = headers,
        body    = {
          image           = Config.application.image,
          entrypoint      = "ardoises-editor",
          run_command     = arguments,
          autorestart     = "OFF",
          autodestroy     = "ALWAYS",
          autoredeploy    = false,
          container_ports = {
            { protocol   = "tcp",
              inner_port = 8080,
              published  = true,
            },
          },
          container_envvars = {
            { key   = "DOCKER_USER",
              value = Config.docker.username,
            },
            { key   = "DOCKER_SECRET",
              value = Config.docker.api_key,
            },
          },
        },
      }
      assert (service_status == 201, service_status)
      -- Editor service:
      service = url .. service.resource_uri
      editor:update {
        docker = service,
      }
      local _, started_status = Http {
        url     = service .. "start/",
        method  = "POST",
        headers = headers,
        timeout = 10, -- seconds
      }
      assert (started_status == 202, started_status)
      local start = gettime ()
      while gettime () - start <= 120 do
        job:heartbeat()
        local result, status = Http {
          url     = service,
          method  = "GET",
          headers = headers,
        }
        assert (status == 200, status)
        if status == 200 and result.state:lower () ~= "starting" then
          local container, container_status = Http {
            url     = url .. result.containers [1],
            method  = "GET",
            headers = headers,
          }
          assert (container_status == 200, container_status)
          for _, port in ipairs (container.container_ports) do
            local endpoint = port.endpoint_uri
            if endpoint and endpoint ~= Json.null then
              if endpoint:sub (-1) == "/" then
                endpoint = endpoint:sub (1, #endpoint-1)
              end
              editor:update {
                url = endpoint:gsub ("^http", "ws"),
              }
              return
            end
          end
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
else
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
end

return Start
