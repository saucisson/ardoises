local Model  = require "lapis.db.model".Model
local result = {}

result.accounts     = Model:extend ("accounts", {})
result.repositories = Model:extend ("repositories", {})
result.permissions  = Model:extend ("permissions", {
  primary_key = { "repository", "account" },
})
result.editors      = Model:extend ("editors", {
  primary_key = { "repository" },
})

return result
