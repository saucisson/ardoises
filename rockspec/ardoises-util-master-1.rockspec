package = "ardoises-util"
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
  "lua-cjson",
  "luasec",
  "luasocket",
  "lustache",
  "net-url",
  "rapidjson",
  "redis-lua",
}

build = {
  type    = "builtin",
  modules = {
    ["ardoises.jsonhttp"       ] = "src/ardoises/jsonhttp.lua",
    ["ardoises.patterns"       ] = "src/ardoises/patterns.lua",
    ["ardoises.util.jsonhttp"  ] = "src/ardoises/util/jsonhttp.lua",
  },
  install = {
    bin = {
      ["ardoises-clean"     ] = "src/ardoises/util/clean.lua",
      ["ardoises-invitation"] = "src/ardoises/util/invitation.lua",
      ["ardoises-permission"] = "src/ardoises/util/permission.lua",
    },
  },
}
