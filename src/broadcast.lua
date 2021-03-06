-- IMPORTS
local json = require("cjson")
local str = require("resty.string")
local resty_sha224 = require("resty.sha224")
local config = require("config")

-- VARS
local txns = ngx.shared.txns
local expire_time = 5
local request_status = {
    -- when 'bypass' is true, do not send any mirror requests
    ["id"] = nil,
    ["msg"] = nil,
    ["bypass"] = false,
}

-- FUNCS
local function get_network()
    if config.network() == nil then
        return ngx.var.arg_chain_id
    else
        return config.network()
    end
end

local function is_dryrun()
    return ngx.var.arg_dryrun ~= nil
end

local function log(log_level, msg, request_data)
    -- When calling 'log' from inside of a thread, ngx.var is unavailable,
    -- in which case we pass in those vars explicitly (via request_data)
    request_data = request_data
        or {
            request_id = ngx.var.request_id,
            remote_user = ngx.var.remote_user,
            http_host = ngx.var.http_host,
            chain_id = get_network(),
        }
    msg.log_level = log_level

    for key, value in pairs(request_data) do
        msg[key] = value
    end

    ngx.log(log_level, json.encode(msg))
end

local function txn_seen(txn)
    -- returns false if we should process this txn
    -- returns true if txn already seen (skip it)
    -- entries are evicted after expire_time seconds, to allow for legitimate
    -- rebroadcasting in the event of a reorg
    local sha224 = resty_sha224:new()
    sha224:update(txn)
    local hex = str.to_hex(sha224:final())
    log(ngx.INFO, { msg = "Transaction hashed", hash = hex })
    local success, err, _ = txns:add(hex, "", expire_time)
    if not success then
        if err == "exists" then
            -- already handled
            return true
        elseif err == "no memory" then
            -- shouldn't happen, since it will evict LRU
            log(ngx.WARN, { msg = "Txns dict out of space and LRU evict failed." })
            return false
        end
    end
    return false
end

local function validate(value)
    log(ngx.INFO, { msg = "Received transaction", body = value })
    -- We set the response ID to that of the first request
    -- When multiple requests are batched, the ID of the last error is returned
    if request_status.msg == nil and request_status.id == nil then
        request_status.id = value.id
    end

    if value.method == nil then
        local msg = "Malformed request, no method set"
        log(ngx.WARN, { msg = msg, id = value.id })
        request_status.msg = msg
        request_status.id = value.id
        return
    end

    if value.method == "web3_clientVersion" then
        request_status.msg = config.version()
        request_status.bypass = true
        return
    end

    if value.method == "eth_chainId" then
        request_status.msg = string.format("%#x", tonumber(get_network()))
        request_status.bypass = true
        return
    end

    if value.method ~= "eth_sendRawTransaction" then
        -- WARN on unimplemented methods
        local msg = "Unsupported RPC call"
        log(ngx.WARN, { msg = msg, call = value.method, id = value.id })
        request_status.msg = msg
        request_status.id = value.id
        return
    end

    if value.params == nil or value.params[1] == nil or string.len(value.params[1]) == 0 then
        local msg = "Malformed request, no params set"
        log(ngx.WARN, { msg = msg, id = value.id })
        request_status.msg = msg
        request_status.id = value.id
        return
    end

    if not is_dryrun() then
        -- checks if txn hash has been seen, if not, adds to list of seen hashes
        if txn_seen(value.params[1]) then
            log(ngx.INFO, { msg = "Transaction already seen, skipping.", id = value.id })
            return
        end
    end

    return value
end

local function mirror(_, provider, body, request_data)
    -- Func runs in separate thread
    local req_body = ""
    local req_uri = ""
    local req_headers = nil

    -- Switch based on provider type, currently supports 3 formats:
    -- standard JSON-RPC message format, with authentication via URL params or HTTP basic auth
    -- and 'etherscan' format, using an Etherscan API key and passing txn data in a URL param
    if provider.type == "json-rpc" then
        req_body = json.encode(body)
        req_uri = provider.uri
        req_headers = {
            ["Content-Type"] = "application/json",
        }
    elseif provider.type == "json-rpc-with-basic-auth" then
        req_body = json.encode(body)
        req_uri = provider.uri
        req_headers = {
            ["Authorization"] = "Basic " .. ngx.encode_base64(provider.auth.user .. ":" .. provider.auth.pass),
            ["Content-Type"] = "application/json",
        }
    elseif provider.type == "etherscan" then
        -- etherscan needs all txn data in the URL, not body
        req_uri = provider.uri .. "&hex=" .. ngx.escape_uri(body.params[1], 2)
        req_body = ""
    else
        log(ngx.ERR, { msg = "Unsupported provider", provider = provider.name, type = provider.type }, request_data)
        return
    end

    log(ngx.INFO, { msg = "Mirroring transaction", provider = provider.name }, request_data)

    local httpc = require("resty.http").new()
    local result, err = httpc:request_uri(req_uri, {
        method = "POST",
        body = req_body,
        headers = req_headers,
    })
    if not result then
        log(ngx.ERR, { msg = "Failed creating mirror request", provider = provider.name, error = err }, request_data)
        return
    end

    if result.status == 200 then
        local _, rpc_result = pcall(json.decode, result.body)
        if rpc_result.error ~= nil then
            log(
                ngx.WARN,
                { msg = "Provider error broadcasting transaction", provider = provider.name, error = rpc_result.error },
                request_data
            )
        else
            log(ngx.INFO, { msg = "Transaction accepted", provider = provider.name }, request_data)
        end
    else
        log(
            ngx.WARN,
            { msg = "Provider returned error", provider = provider.name, status = result.status, body = result.body },
            request_data
        )
    end
end

ngx.req.read_body()
local data = ngx.req.get_body_data()
if ngx.req.get_method() ~= "POST" or data == nil then
    log(ngx.INFO, { msg = "Non-POST or empty body, ignoring" })
    ngx.status = ngx.HTTP_OK
    return
end

if get_network() == nil then
    log(ngx.ERR, { msg = "No CHAINID env var set and no chain_id URL parameter sent" })
    ngx.status = ngx.HTTP_BAD_REQUEST
    return
end

local status, values = pcall(json.decode, data)
if not status then
    log(ngx.WARN, { msg = "Failed parsing body (not JSON?)", body = data })
    ngx.status = ngx.HTTP_BAD_REQUEST
    return
end

if values[1] == nil and values.jsonrpc ~= nil then
    -- lua arrays are just integer indexed dicts
    values = { values } -- make single item list
end

for _, value in ipairs(values) do
    -- since we can have multiple txns per request,
    -- nginx returns status of last parsed transaction
    local body = validate(value)
    if body ~= nil and request_status.bypass ~= true and not is_dryrun() then
        for _, provider in config.providers(get_network()) do
            -- threads dont have access to ngx.var, pass in for logging
            local request_data = {
                request_id = ngx.var.request_id,
                remote_user = ngx.var.remote_user,
                http_host = ngx.var.http_host,
                chain_id = get_network(),
            }
            -- process via background lua threads, nonblocking
            ngx.timer.at(0, mirror, provider, body, request_data)
        end
    end
end

local response = {
    ["jsonrpc"] = "2.0",
    ["id"] = request_status.id,
}

if request_status.msg == nil or request_status.bypass == true then
    if request_status.msg ~= nil then
        response.result = request_status.msg
    else
        response.result = ""
    end
    ngx.status = ngx.HTTP_OK
else
    response.error = {
        ["code"] = -32000,
        ["message"] = request_status.msg,
    }
    ngx.status = ngx.HTTP_BAD_REQUEST
end

ngx.say(json.encode(response))

return
