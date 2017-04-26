local Lustache = require "lustache"
local Url      = require "net.url"

local result = {
  patterns = {
    id = function (what)
      return Lustache:render ("ardoises:id:{{{what}}}", { what = what })
    end,
    lock = function (what)
      return Lustache:render ("ardoises:lock:{{{what}}}", { what = what })
    end,
    user = function (user)
      return Lustache:render ("ardoises:user:{{{login}}}", user)
    end,
    repository = function (repository)
      return Lustache:render ("ardoises:repository:{{{owner.login}}}/{{{name}}}", repository)
    end,
    collaborator = function (repository, collaborator)
      return Lustache:render ("ardoises:collaborator:{{{repository.owner.login}}}/{{{repository.name}}}/{{{collaborator.login}}}", {
        repository   = repository,
        collaborator = collaborator,
      })
    end,
    editor = function (repository, branch)
      return Lustache:render ("ardoises:editor:{{{repository.owner.login}}}/{{{repository.name}}}/{{{branch}}}", {
        repository = repository,
        branch     = branch,
      })
    end,
    tool = function (owner, tool)
      return Lustache:render ("ardoises:tool:{{{owner.login}}}/{{{tool.id}}}", {
        owner = owner,
        tool  = tool,
      })
    end,
  },
  docker_id   = assert (os.getenv "HOSTNAME"),
  ardoises    = assert (Url.parse (os.getenv "ARDOISES_URL")),
  docker      = assert (Url.parse (os.getenv "DOCKER_URL"  )),
  redis       = assert (Url.parse (os.getenv "REDIS_URL"   )),
  application = {
    id     = assert (os.getenv "APPLICATION_ID"),
    secret = assert (os.getenv "APPLICATION_SECRET"),
    token  = assert (os.getenv "APPLICATION_TOKEN"),
  },
  locks = {
    timeout = 5, -- seconds
  }
}

result.ardoises.url = tostring (result.ardoises)
result.docker  .url = tostring (result.docker)
result.redis   .url = tostring (result.redis)

return result
