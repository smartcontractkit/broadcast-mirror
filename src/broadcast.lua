-- IMPORTS
local json = require("cjson")
local str = require("resty.string")
local resty_sha224 = require("resty.sha224")
local config = require("config")

-- VARS
local txns = ngx.shared.txns

-- FUNCS
local function log(log_level, msg, request_data)
    -- When calling 'log' from inside of a thread, ngx.var is unavailable,
    -- in which case we pass in those vars explicitly (via request_data)
    request_data = request_data
        or { request_id = ngx.var.request_id, remote_user = ngx.var.remote_user, http_host = ngx.var.http_host }
    msg.log_level = log_level
    msg.network = config.network()

    for key, value in pairs(request_data) do
        msg[key] = value
    end

    ngx.log(log_level, json.encode(msg))
end

local function txn_seen(txn)
    -- returns false if we should process this txn
    -- returns true if txn already seen (skip it)
    local sha224 = resty_sha224:new()
    sha224:update(txn)
    local hex = str.to_hex(sha224:final())
    log(ngx.INFO, { msg = "Transaction hashed", hash = hex })
    local success, err, _ = txns:add(hex, "")
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

    if value.method == nil then
        log(ngx.WARN, { msg = "Malformed request, no method set" })
        ngx.status = ngx.HTTP_BAD_REQUEST
        return
    end

    if value.method ~= "eth_sendRawTransaction" then
        log(ngx.INFO, { msg = "Unsupported RPC call", call = value.method })
        ngx.status = ngx.HTTP_OK
        return
    end

    if value.params == nil or value.params[1] == nil or string.len(value.params[1]) == 0 then
        log(ngx.WARN, { msg = "Malformed request, no params set" })
        ngx.status = ngx.HTTP_BAD_REQUEST
        return
    end

    if txn_seen(value.params[1]) then
        log(ngx.INFO, { msg = "Transaction already seen, skipping." })
        ngx.status = ngx.HTTP_OK
        return
    else
        return value
    end
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
    if body ~= nil then
        ngx.status = ngx.HTTP_OK
        for _, provider in config.providers() do
            -- threads dont have access to ngx.var, pass in for logging
            local request_data = {
                request_id = ngx.var.request_id,
                remote_user = ngx.var.remote_user,
                http_host = ngx.var.http_host,
            }
            -- process via background lua threads, nonblocking
            ngx.timer.at(0, mirror, provider, body, request_data)
        end
    end
end

return
