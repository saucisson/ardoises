local Config  = require "lapis.config".get ()
local Et      = require "etlua"
local Http    = require "ardoises.jsonhttp".resty
local Json    = require "cjson"
local Mime    = require "mime"
local Model   = require "ardoises.server.model"
local gettime = require "socket".gettime

local Start = {}

function Start.perform (job)
  local editor = Model.editors:create {
    repository = job.data.repository.full_name,
    branch     = job.data.branch,
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
  local arguments = Et.render ([[ --application=<%- application %> <%- repository %> <%- token %> ]], {
    application = Config.gh_app_name,
    token       = job.data.token,
    repository  = Et.render ("<%- repository %>:<%- branch %>", {
      repository = job.data.repository.full_name,
      branch     = job.data.branch,
    }),
  })
  pcall (function ()
    -- Create service:
    local service, service_status = Http {
      url     = api .. "/service/",
      method  = "POST",
      headers = headers,
      body    = {
        image           = "ardoises/editor:dev",
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
              url = endpoint,
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

return Start
