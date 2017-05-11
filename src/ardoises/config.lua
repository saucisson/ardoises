local Url = require "net.url"
local Data

do
  local file = assert (io.open ("/etc/ardoises/config.lua", "r"))
  local data = assert (file:read "*a")
  file:close ()
  Data = assert (_G.load (data, "/etc/ardoises/config.lua")) ()
end

local result = {
  ardoises = {
    url = Data.ardoises
      and Data.ardoises.url
      and assert (Url.parse (Data.ardoises.url))
       or "https://ardoises.ovh",
  },
  docker = {
    url = Data.docker
      and Data.docker.url
      and assert (Url.parse (Data.docker.url))
       or assert (Url.parse ("tcp://docker:2375")),
    container = assert (os.getenv "HOSTNAME"),
  },
  redis  = {
    url = Data.redis
      and Data.redis.url
      and assert (Url.parse (Data.redis.url))
       or assert (Url.parse ("tcp://redis:6379")),
  },
  github = {
    id     = assert (Data.github and Data.github.id),
    secret = assert (Data.github and Data.github.secret),
    token  = assert (Data.github and Data.github.token),
  },
  twilio = {
    username = Data.twilio and Data.twilio.username,
    password = Data.twilio and Data.twilio.password,
    phone    = Data.twilio and Data.twilio.phone,
  },
  administrator = {
    phone = Data.administrator and Data.administrator.phone,
    email = Data.administrator and Data.administrator.email,
  },
  locks = {
    timeout = Data.locks
          and Data.locks.timeout
           or 5, -- seconds
  },
  test = Data.test,
}

if type (result.administrator.phone) ~= "table" then
  result.administrator.phone = { result.administrator.phone }
end
if type (result.administrator.email) ~= "table" then
  result.administrator.email = { result.administrator.email }
end

return result
