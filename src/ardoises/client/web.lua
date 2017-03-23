print "Running web client"

local Adapter = require "ardoises.client.js"
local Client  = require "ardoises.client"
local Copas   = require "copas"

local client  = Client {
  server = "http://localhost:8080",
  token  = "{{user.token}}",
}
print ("client:", client)
local repositories = client:repositories ()
print ("repositories:", #repositories)
for _, data in ipairs (repositories) do
  print (data.repository.full_name)
end
print ("end")
