local Config = require "lapis.config"
local Url    = require "socket.url"

local postgres_url = assert (Url.parse (os.getenv "POSTGRES_PORT"))
local redis_url    = assert (Url.parse (os.getenv "REDIS_PORT"   ))

local common = {
  host         = "localhost",
  port         = 8080,
  num_workers  = 1,
  session_name = "ardoises",
  application = {
    id     = assert (os.getenv "APPLICATION_ID"    ),
    name   = assert (os.getenv "APPLICATION_NAME"  ),
    secret = assert (os.getenv "APPLICATION_SECRET"),
    state  = assert (os.getenv "APPLICATION_STATE" ),
    user   = assert (os.getenv "ARDOISES_USER"     ),
    token  = assert (os.getenv "ARDOISES_TOKEN"    ),
  },
  postgres = {
    backend  = "pgmoon",
    host     = assert (postgres_url.host),
    port     = assert (postgres_url.port),
    user     = assert (os.getenv "POSTGRES_USER"    ),
    password = assert (os.getenv "POSTGRES_PASSWORD"),
    database = assert (os.getenv "POSTGRES_DATABASE"),
  },
  redis = {
    host     = assert (redis_url.host),
    port     = assert (redis_url.port),
    database = 0,
  },
  docker = {
    username = assert (os.getenv "DOCKER_USER"  ),
    api_key  = assert (os.getenv "DOCKER_SECRET"),
  },
  clean = {
    delay = 60,
  },
  invitation = {
    delay = 60,
  },
}

Config ({ "test", "development", "production" }, common)
