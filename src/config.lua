local config = {}

local json = require("cjson")

local config_path = "/app/networks.json"
local file = io.open(config_path, "r")
local content = file:read("*a")
file:close()

local _, parsed = pcall(json.decode, content)
local network = os.getenv("ETH_NETWORK")
local providers = parsed[network]

if not providers then
    ngx.log(ngx.ERR, "Missing required environment variables")
    os.exit()
end

function config.network()
    return network
end

function config.providers()
    return ipairs(providers)
end

return config
