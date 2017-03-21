local Lustache = require "lustache"
local Url      = require "net.url"

local result = {
  patterns = {
    user         = function (user)
      return Lustache:render ("ardoises:user:{{{login}}}", user)
    end,
    repository   = function (repository)
      return Lustache:render ("ardoises:repository:{{{owner.login}}}/{{{name}}}", repository)
    end,
    collaborator = function (repository, collaborator)
      return Lustache:render ("ardoises:collaborator:{{{repository.owner.login}}}/{{{repository.name}}}/{{{collaborator.login}}}", {
        repository   = repository,
        collaborator = collaborator,
      })
    end,
  },
  ardoises = assert (Url.parse (os.getenv "ARDOISES_URL")),
  docker   = assert (Url.parse (os.getenv "DOCKER_URL"  )),
  redis    = assert (Url.parse (os.getenv "REDIS_URL"   )),
  application = {
    id     = assert (os.getenv "APPLICATION_ID"),
    secret = assert (os.getenv "APPLICATION_SECRET"),
    token  = assert (os.getenv "APPLICATION_TOKEN"),
  },
}

result.ardoises.url = tostring (result.ardoises)
result.docker  .url = tostring (result.docker)
result.redis   .url = tostring (result.redis)

return result
