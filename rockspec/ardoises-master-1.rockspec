package = "ardoises"
version = "master-1"
source  = {
  url    = "git+https://github.com/ardoises/ardoises.git",
  branch = "master",
}

description = {
  summary    = "Ardoises",
  detailed   = [[]],
  homepage   = "https://github.com/ardoises",
  license    = "MIT/X11",
  maintainer = "Alban Linard <alban@linard.fr>",
}

dependencies = {
  "lua >= 5.1",
  "argparse",
  "copas",
  "coronest",
  "dkjson",
  "etlua",
  "hashids",
  "jwt",
  "lpeg",
  "layeredata",
  "luaossl",
  "luaposix",
  "luasec",
  "luasocket",
  "lua-resty-cookie",
  "lua-resty-http",
  "lua-resty-jwt",
  "lua-websockets",
  "lustache",
  "net-url",
  "rapidjson",
  "redis-lua",
}

build = {
  type    = "builtin",
  modules = {
    ["ardoises.jsonhttp.common"      ] = "src/ardoises/jsonhttp/common.lua",
    ["ardoises.jsonhttp.copas"       ] = "src/ardoises/jsonhttp/copas.lua",
    ["ardoises.jsonhttp.resty-redis" ] = "src/ardoises/jsonhttp/resty-redis.lua",
    ["ardoises.jsonhttp.socket"      ] = "src/ardoises/jsonhttp/socket.lua",
    ["ardoises.jsonhttp.socket-redis"] = "src/ardoises/jsonhttp/socket-redis.lua",
    ["ardoises.patterns"             ] = "src/ardoises/patterns.lua",
    ["ardoises.client"               ] = "src/ardoises/client/init.lua",
    ["ardoises.config"               ] = "src/ardoises/config.lua",
    ["ardoises.editor"               ] = "src/ardoises/editor/init.lua",
    ["ardoises.editor.bin"           ] = "src/ardoises/editor/bin.lua",
    ["ardoises.sandbox"              ] = "src/ardoises/sandbox.lua",
    ["ardoises.server"               ] = "src/ardoises/server/init.lua",
    ["ardoises.server.bin"           ] = "src/ardoises/server/bin.lua",
    ["ardoises.util.clean"           ] = "src/ardoises/util/clean.lua",
    ["ardoises.util.invitation"      ] = "src/ardoises/util/invitation.lua",
    ["ardoises.util.populate"        ] = "src/ardoises/util/populate.lua",
    ["ardoises.util.webhook"         ] = "src/ardoises/util/webhook.lua",
  },
}
