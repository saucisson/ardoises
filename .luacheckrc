cache     = false
codes     = false
color     = true
formatter = "default"
std       = "luajit"
files ["**/*_spec.lua"] = {
  std = "+busted",
}
