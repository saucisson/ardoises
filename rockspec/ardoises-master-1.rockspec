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
  "basexx",
  "c3",
  "copas",
  "coronest",
  "dkjson",
  "etlua",
  "jwt",
  "lpeg",
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
  "uuid",
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
    ["ardoises.editor.test"          ] = "src/ardoises/editor/test.lua",
    ["ardoises.data"                 ] = "src/ardoises/data/init.lua",
    ["ardoises.sandbox"              ] = "src/ardoises/sandbox.lua",
    ["ardoises.server"               ] = "src/ardoises/server/init.lua",
    ["ardoises.server.keys"          ] = "src/ardoises/server/keys.lua",
    ["ardoises.server.bin"           ] = "src/ardoises/server/bin.lua",
    ["ardoises.util.clean"           ] = "src/ardoises/util/clean.lua",
    ["ardoises.util.invitation"      ] = "src/ardoises/util/invitation.lua",
    ["ardoises.util.limits"          ] = "src/ardoises/util/limits.lua",
    ["ardoises.util.populate"        ] = "src/ardoises/util/populate.lua",
    ["ardoises.util.webhook"         ] = "src/ardoises/util/webhook.lua",
    ["ardoises.www.loader"           ] = "src/ardoises/www/loader.lua",
    ["ardoises.www.dashboard"        ] = "src/ardoises/www/dashboard.lua",
    ["ardoises.www.editor"           ] = "src/ardoises/www/editor.lua",
    ["ardoises.www.overview"         ] = "src/ardoises/www/overview.lua",
    ["ardoises.www.register"         ] = "src/ardoises/www/register.lua",
  },
  install = {
    bin = {
      ["ardoises-test"] = "src/ardoises/editor/test.lua",
    },
  },
}
