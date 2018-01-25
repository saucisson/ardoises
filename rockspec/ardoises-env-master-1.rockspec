package = "ardoises-env"
version = "master-1"
source  = {
  url    = "git+https://github.com/ardoises/ardoises.git",
  branch = "master",
}

description = {
  summary    = "Ardoises: dev dependencies",
  detailed   = [[]],
  homepage   = "https://github.com/orgs/ardoises",
  license    = "MIT/X11",
  maintainer = "Alban Linard <alban@linard.fr>",
}

dependencies = {
  "lua >= 5.1",
  "busted",
  "cluacov",
  "copas",
  "etlua",
  "hashids",
  "jwt",
  "luacheck",
  "luacov",
  "luacov-coveralls",
  "luasocket",
  "luasec",
  "lua-cjson",
  "lua-websockets",
}

build = {
  type    = "builtin",
  modules = {},
}
