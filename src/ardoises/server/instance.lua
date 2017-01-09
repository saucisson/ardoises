local Mime    = require "mime"
local Hashids = require "hashids"
local Json    = require "rapidjson"
local Http    = require "ardoises.jsonhttp".default

local url = "https://cloud.docker.com"
local api = url .. "/api/app/v1/ardoises"

local Instance = {}
Instance.__index = Instance

local headers = {
  ["Authorization"] = "Basic " .. Mime.b64 (os.getenv "DOCKER_USER" .. ":" .. os.getenv "DOCKER_SECRET"),
  ["Accept"       ] = "application/json",
  ["Content-type" ] = "application/json",
}

function Instance.create ()
  local instance = setmetatable ({
    docker  = nil,
    server  = nil,
  }, Instance)
  -- Create service:
  local id  = "ardoises-" .. Hashids.new (tostring (os.time ())):encode (666)
  local stack, stack_status = Http {
    url     = api .. "/stack/",
    method  = "POST",
    headers = headers,
    body    = {
      name     = id,
      services = {
        { name  = "postgres",
          image = "postgres",
        },
        { name  = "redis",
          image = "redis:3.0.7",
        },
        { name       = "ardoises",
          image      = "ardoises/ardoises:dev", -- FIXME: switch to master branch
          entrypoint = "ardoises-server",
          ports      = { "8080" },
          links      = {
            "postgres",
            "redis",
          },
          environment = {
            REDIS_PORT        = "tcp://redis:6379",
            POSTGRES_PORT     = "tcp://postgres:5432",
            POSTGRES_USER     = "postgres",
            POSTGRES_PASSWORD = "",
            POSTGRES_DATABASE = "postgres",
            DOCKER_USER       = os.getenv "DOCKER_USER",
            DOCKER_SECRET     = os.getenv "DOCKER_SECRET",
            GH_CLIENT_ID      = os.getenv "GH_CLIENT_ID",
            GH_CLIENT_SECRET  = os.getenv "GH_CLIENT_SECRET",
            GH_OAUTH_STATE    = "some state",
            GH_APP_NAME       = "Ardoises",
            ARDOISES_SECRET   = "some secret",
          },
        },
      },
    },
  }
  assert (stack_status == 201)
  -- Start service:
  instance.docker = url .. stack.resource_uri
  local _, started_status = Http {
    url        = instance.docker .. "start/",
    method     = "POST",
    headers    = headers,
    timeout    = 5, -- seconds
  }
  assert (started_status == 202, started_status)
  assert (instance:find_endpoint ())
  return instance
end

function Instance.find_endpoint (instance)
  local services
  do
    local result, status
    while true do
      result, status = Http {
        url     = instance.docker,
        method  = "GET",
        headers = headers,
      }
      if status == 200 and result.state:lower () ~= "starting" then
        services = result.services
        break
      else
        os.execute "sleep 1"
      end
    end
    assert (result.state:lower () == "running")
  end
  for _, path in ipairs (services) do
    local service, service_status = Http {
      url     = url .. path,
      method  = "GET",
      headers = headers,
    }
    assert (service_status == 200)
    if service.name == "ardoises" then
      local container, container_status = Http {
        url     = url .. service.containers [1],
        method  = "GET",
        headers = headers,
      }
      assert (container_status == 200)
      for _, port in ipairs (container.container_ports) do
        local endpoint = port.endpoint_uri
        if endpoint and endpoint ~= Json.null then
          if endpoint:sub (-1) == "/" then
            endpoint = endpoint:sub (1, #endpoint-1)
          end
          instance.server = endpoint
          return instance.server
        end
      end
    end
  end
end

function Instance.delete (instance)
  while true do
    local _, deleted_status = Http {
      url     = instance.docker,
      method  = "DELETE",
      headers = headers,
    }
    if deleted_status == 202 or deleted_status == 404 then
      break
    else
      os.execute "sleep 1"
    end
  end
end

return Instance
