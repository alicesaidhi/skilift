local flags = require("./flags")
local types = require("./types")
local retry = require("./retry")
local task = require("./task")

local TRANSACTION_NAME = "_$SKILIFT_TRANSACTION"
local TRANSACTION_SCOPE = "global"

local cached_transaction_status = {}

type TransactionInfo = types.TransactionInfo
type TransactionId = types.TransactionId
type CompletionStatus = "failed" | "completed" | "unknown"

local function request_for_transaction(id: TransactionId)
    local TRANSACTION_STORE = flags.datastoreservice:GetDataStore(TRANSACTION_NAME, TRANSACTION_SCOPE)

    local result: boolean? = retry.exponential_backoff(function()
        return TRANSACTION_STORE:GetAsync(id)
    end)

    cached_transaction_status[id] = if result then true else false
end

local function is_transaction_complete(id: TransactionId): CompletionStatus
    local value = cached_transaction_status[id]
    if value == true then
        return "completed"
    elseif value == false then
        return "failed"
    else
        task.spawn(request_for_transaction, id)
        if cached_transaction_status[id] then return "completed" end -- the transaction was stored in the cache
        return "unknown"
    end
end

local function set_transaction_status(id: TransactionId, ok: boolean)
    cached_transaction_status[id] = ok
end

return {
    request_for_transaction = request_for_transaction,
    is_transaction_complete = is_transaction_complete,
    set_transaction_status = set_transaction_status,
}