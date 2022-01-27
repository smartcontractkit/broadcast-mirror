local config = {}

local json = require("cjson")

local config_env = os.getenv("NETCONFIG_PATH")
local config_path = "/app/networks.json"
if config_env ~= nil then
    config_path = config_env
end

local file = io.open(config_path, "r")
local content = file:read("*a")
file:close()

local _, parsed = pcall(json.decode, content)
local network = os.getenv("ETH_NETWORK")

function config.network()
    return network
end

function config.providers(network)
    local providers = parsed[network]

    -- handle unsupported networks
    if providers == nil then
        return {}
    end

    return ipairs(providers)
end

return config
