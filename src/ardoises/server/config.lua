local Config = require "lapis.config"
local Url    = require "socket.url"

local postgres_url = assert (Url.parse (os.getenv "POSTGRES_PORT"))
local redis_url    = assert (Url.parse (os.getenv "REDIS_PORT"   ))

local common = {
  host             = "localhost",
  port             = 8080,
  num_workers      = 1,
  gh_client_id     = assert (os.getenv "GH_CLIENT_ID"),
  gh_client_secret = assert (os.getenv "GH_CLIENT_SECRET"),
  gh_oauth_state   = assert (os.getenv "GH_OAUTH_STATE"),
  gh_app_name      = assert (os.getenv "GH_APP_NAME"),
  session_name     = "ardoises",
  secret           = assert (os.getenv "ARDOISES_SECRET"),
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
    delay = 10,
  }
}

Config ({ "test", "development", "production" }, common)
