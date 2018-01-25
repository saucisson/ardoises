local Lustache = require "lustache"

return {
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
}
