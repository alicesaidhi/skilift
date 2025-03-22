local types = require("./types")
local budget = require("./budget")
local retry = require("./retry")
local LOG = require("./log")
local actions = require("./actions")
local flags = require("./flags")
local task = require("./task")
local transaction = require("./checktransaction")
local util = require("./util")
local THROW = require("./throw")

local AUTOSAVE_DELAY = 15

local profilebegin = debug.profilebegin or function() end :: never
local profileend = debug.profileend or function() end :: never

local NOOP = function() end

type JSON = types.JSON
type Action<T=any, U...=...any> = types.Action<T, U...>
type Store<T> = types.Store<T>
type Session<T> = types.Session<T>
type StoredData<T> = types.StoredData<T>
type TransactionId = types.TransactionId
type TransactionInfo = types.TransactionInfo
type TransactionAction = types.TransactionAction
type TransactionData = types.TransactionData

local function merge<T>(a: { T }, b: { T }): { T }
    local dst = table.create(#a + #b)
    table.move(a, 1, #a, 1, dst)
    table.move(b, 1, #b, #a + 1, dst)
    return dst
end

local function migrate<T>(session: Session<T>, stored: StoredData<T>)
    local migrations = session._.options.migrations

    if #migrations == #stored.migrations_performed then return false end
    LOG(`{session.name}: Performing Migration`)
    for i, migration in migrations do
        if table.find(stored.migrations_performed, migration.step) then continue end
        LOG(`{session.name}: Migration Step {migration.step}`)

        local result = migration.migrate(stored.data)
        if result == nil then THROW("migration_does_not_return", migration.step) end
        stored.data = result

        table.insert(stored.migrations_performed, migration.step)
    end
    return true
end

local function perform_transaction<T>(store: Store<T>, stored: StoredData<T>, action: TransactionAction)
    local fn = actions.obtain_transaction_action(store, action.fn)
    local values = action.values

    local result = fn(util.clone(stored.data), unpack(values))
    if result == nil then THROW("action_does_not_return", action.fn) end
    stored.data = result
end

local function create_migrations_table(session: Session<any>)
    local migrations = {}
    for i, migration in session._.options.migrations do
        table.insert(migrations, migration.step)
    end
    return migrations
end

local function check_transaction<T>(store: Store<T>, session: Session<T>, data: StoredData<T>)
    for _, info in data.pending_transactions do
        for _, value in info.success do
            if store._transaction_names[value.fn] then continue end
            session._.why_bad = `Transaction could not be processed: Unable to recognize the action "{value.fn}"`
            LOG(session._.why_bad)
            return false
        end
    end
    return true
end

local function check_migrations<T>(session: Session<T>, data: StoredData<T>)
    local t = create_migrations_table(session)
    for _, migration in data.migrations_performed do
        if table.find(t, migration) then continue end
        session._.why_bad = `Migration could not be completed: Unable to apply "{migration}"`
        LOG(session._.why_bad)
        return false
    end
    return true
end

local function run_updated<T>(session: Session<T>)
    local data = session._.cached.data
    local fn = session._.updated
    local copy = util.deep_freeze(util.clone(data))

    return fn(copy)
end

local function update<T>(
    session: Session<T>,
    changes: { { Action<any, ...any> & any } },
    pending_transactions: { [TransactionId]: TransactionData },
    stored: StoredData<T>,
    db_key_info: DataStoreKeyInfo?
): StoredData<T>?

    local store = session._.store
    local did_anything = false
    local is_nil = stored == nil
    if stored == nil then
        stored = {
            pending_transactions = {},
            migrations_performed = create_migrations_table(session),
            data = session._.options.default_data()
        }
    end

    LOG(`Applying {#changes} changes to {session.name}`)

    if not check_migrations(session, stored) then
        session._.finished = "done"
        return nil
    end
    if not check_transaction(store, session, stored) then session._.finished = "done"; return nil end

    for id, data in stored.pending_transactions do
        local status: "completed" | "failed" | "unknown" = transaction.is_transaction_complete(id)
        LOG(`{session.name}: Pending Transaction Status {id}: {status}`)
        if status == "completed" then
            for _, action in data.success do
                perform_transaction(store, stored, action)
            end
            stored.pending_transactions[id] = nil
            did_anything = true
        elseif status == "failed" then
            for _, action in data.failure do
                perform_transaction(store, stored, action)
            end
            stored.pending_transactions[id] = nil
            did_anything = true
        elseif status == "unknown" then
            -- transaction status is unknown. nothing happens
        else
            error("unhandled case")
        end
    end

    if migrate(session, stored) then did_anything = true end

    for id, data in pending_transactions do
        LOG(`Added transaction {id} to {session.name}`)
        stored.pending_transactions[id] = data
        did_anything = true
    end

    for _, action in changes do
        local fn = action[1]
        LOG("Applying action with", unpack(action, 2))
        local result = fn(stored.data, unpack(action, 2))
        if result == nil then THROW("action_does_not_return", debug.info(fn, "n")) end
        stored.data = result
        did_anything = true
    end

    if did_anything == false and not is_nil then
        LOG(`No data has updated for {session.name}. Cancelling update.`)
        return nil
    end

    LOG(`Returning updated data for {session.name}`)

    return stored, session._.user_ids
end

local function pull_auto<T>(session: Session<T>, transactions: { [TransactionId]: TransactionData })

    local old_changes = session._.changes
    local store, key = session._.datastore, session.key

    session._.changes = {}
    session._.next_save_opportunity = math.huge

    budget.delay_until_meets_budget("update", 5)

    LOG("saving", session.name)
    local ok, result: StoredData<T> = pcall(function()
        LOG("attempting auto-save")
        local new_data
        store:UpdateAsync(key, function(value, keyinfo)
            local combined_changes_now = merge(old_changes, session._.changes)
            
            LOG("retrieved", value)
            local updated_value = update(session, combined_changes_now, transactions, value, keyinfo)
            new_data = if updated_value == nil then value else updated_value
            LOG(if updated_value ~= nil then "saved new data" else "cancelled update as no change has been made")
            session._.changes = {}

            return updated_value
        end)

        LOG("FINISHED SAVE")
        session._.changes = {}
        return new_data
    end)

    session._.next_save_opportunity = session._.pull_delay

    if not ok then
        error(`Failed to pull {result}`)
    end
    
    session._.first_request_succeeded = true

    for _, fn in session._.waiting_for_saved do
        fn()
    end
    table.clear(session._.waiting_for_saved)

    if session._.why_bad then 
        error(`Failed to pull as the server has encountered some error: {session._.why_bad}`)
    end

    LOG("value is", result)
    session._.cached = result
    LOG(`{session.name} calling updated -`, debug.info(session._.updated, "sl"))
    run_updated(session)
end

local function force_pull<T>(session: Session<T>)
    LOG("forcing save")
    local old_changes = session._.changes
    local store, key = session._.datastore, session.key

    session._.changes = {}
    session._.next_save_opportunity = math.huge

    local result: StoredData<T> = retry.regular_retry(function()
        LOG("waiting until budget is met")
        budget.delay_until_meets_budget("update", 5)
        local new_data
        LOG("performing save")
        store:UpdateAsync(key, function(value, keyinfo)
            local combined_changes_now = merge(old_changes, session._.changes)
            
            LOG("retrieved", value)
            local updated_value = update(session, combined_changes_now, {}, value, keyinfo)
            new_data = if updated_value == nil then value else updated_value
            LOG(if updated_value ~= nil then "saved new data" else "cancelled update as no change has been made")
            session._.changes = {}

            return updated_value
        end)
        LOG("finished")
        return new_data
    end, 1)
    session._.first_request_succeeded = true

    for _, fn in session._.waiting_for_saved do
        fn()
    end
    table.clear(session._.waiting_for_saved)

    session._.next_save_opportunity = session._.pull_delay
    session._.cached = if result == nil then session._.cached else result
    LOG(`{session.name} calling updated on force`, debug.info(session._.updated, "sl"))
    run_updated(session)
end

local function thread<T>(session: Session<T>)
    while true do
        LOG("performing auto-save in", session._.next_save_opportunity, "for", session.name)
        if session._.next_save_opportunity > 0 then 
            local dt = task.wait()
            session._.next_save_opportunity -= dt
            continue
        end
        LOG("triggering auto-save for", session.name)
        local ok, err: string? = pcall(pull_auto, session, {}) -- silence autosave error if emitted
        if not ok then LOG("autosave error:", err :: string) end
        if session._.why_bad then return end
    end
end

local function patch_transaction<T, U...>(session: Session<T>, fn: Action<T, U...>, ...: U...)
    local store = session._.store

    if flags.strict then
        for i = 1, select("#", ...) do
            local ok, err = pcall(util.check_json_valid, select(i, ...))

            if ok == false then
                THROW("strict_pass_not_json_into_action", tostring(err))
            end
        end

        profilebegin("strict mode")
        local start = session._.cached.data
        local a = util.clone(start)
        a = fn(a, ...)

        local b = util.clone(start)
        b = fn(b, ...)

        -- check if it's valid json in strict mode
        local ok, err = pcall(util.check_json_valid, a)

        if ok == false then
            THROW("strict_not_json_from_action", debug.info(fn, "s"), tostring(err))
        end
        -- it's valid json, but we have to make sure it's pure
        if not util.delta_eq(a, b) then
            THROW("strict_impure_action", debug.info(fn, "sl"))
        end
        profileend()

        if session._.options.schema and not session._.options.schema(a) then
            THROW("schema_validation_error", session.name, debug.info(fn, "n"))
        end
    else
        local result = fn(util.clone(session._.cached.data), ...)

        if session._.options.schema and not session._.options.schema(result) then
            THROW("schema_validation_error", session.name, debug.info(fn, "n"))
        end
    end

    local transaction = flags.processing_transaction :: TransactionInfo
    local records = transaction.sessions[session] or { success = {}, failure = {} }
    local record = actions.create_transaction_record(store, fn, ...)

    if transaction.state == "failure" then
        LOG(`Adding transaction action on failure "{record.fn}" for {session.name}`)
        table.insert(records.failure, record)
    elseif transaction.state == "success" then
        LOG(`Adding transaction action on success "{record.fn}" for {session.name}`)
        table.insert(records.success, record)
    end

    transaction.sessions[session] = records
end

local function patch_regular<T, U...>(session: Session<T>, fn: Action<T, U...>, ...: U...)
    LOG(`Performing "{debug.info(fn, "n")}" for {session.name}`)

    if flags.strict then
        profilebegin("strict mode")
        local start = session._.cached.data
        local a = util.clone(start)
        a = fn(a, ...)

        local b = util.clone(start)
        b = fn(b, ...)

        -- check if it's valid json in strict mode
        local ok, err = pcall(util.check_json_valid, a)

        if ok == false then
            THROW("strict_not_json_from_action", debug.info(fn, "s"), tostring(err))
        end
        -- it's valid json, but we have to make sure it's pure
        if not util.delta_eq(a, b) then
            THROW("strict_impure_action", debug.info(fn, "sl"))
        end
        profileend()

        if session._.options.schema and not session._.options.schema(a) then
            THROW("schema_validation_error", session.name, debug.info(fn, "n"))
        end

        table.insert(session._.changes, actions.create_record(fn, ...) )
        session._.cached.data = a
        run_updated(session)
    else
        local result = fn(session._.cached.data, ...)

        if session._.options.schema and not session._.options.schema(result) then
            THROW("schema_validation_error", session.name, debug.info(fn, "n"))
        end

        table.insert(session._.changes, actions.create_record(fn, ...) )
        session._.cached.data = result
        run_updated(session)
    end
end

local function commit_transaction_early<T, U...>(session: Session<T>, fn: Action<T, U...>, ...: U...)
    LOG(`Performing "{debug.info(fn, "n")}" for {session.name}`)

    if flags.strict then
        profilebegin("strict mode")
        local start = session._.cached.data
        local a = util.clone(start)
        a = fn(a, ...)

        local b = util.clone(start)
        b = fn(b, ...)

        -- check if it's valid json in strict mode
        local ok, err = pcall(util.check_json_valid, a)

        if ok == false then
            THROW("strict_not_json_from_action", debug.info(fn, "s"), tostring(err))
        end
        -- it's valid json, but we have to make sure it's pure
        if not util.delta_eq(a, b) then
            THROW("strict_impure_action", debug.info(fn, "sl"))
        end
        profileend()

        if session._.options.schema and not session._.options.schema(a) then
            THROW("schema_validation_error", session.name, debug.info(fn, "n"))
        end

        session._.cached.data = a
        run_updated(session)
    else
        local result = fn(session._.cached.data, ...)

        if session._.options.schema and not session._.options.schema(result) then
            THROW("schema_validation_error", session.name, debug.info(fn, "n"))
        end

        session._.cached.data = result
    end
end

local function patch<T, U...>(session: Session<T>, fn: Action<T, U...>, ...: U...)
    if session._.finished then THROW("session_already_stopped") end

    actions.ASSERT_ACTION(session._.store, fn)
    if flags.processing_transaction then
        patch_transaction(session, fn, ...)
    else
        patch_regular(session, fn, ...)
    end
end

local function updated<T>(session: Session<T>, new: (data: T) -> ())
    if session._.finished then THROW("session_already_stopped") end
    
    session._.updated = new
    LOG(`{session.name} calling updated register`, debug.info(new, "sl"))
    run_updated(session)
end

local function stop<T>(session: Session<T>)
    if session._.finished ~= false then return end
    session._.finished = "saving"
    session._.updated = NOOP
    task.cancel(session._.thread)
    task.spawn(function()
       force_pull(session)
       session._.finished = "done"
    end)
end

local function await<T>(session: Session<T>)
    if session._.finished == "done" then return end

    local ok = false
    table.insert(session._.waiting_for_saved, function()
        ok = true
    end)
    while not ok do task.wait() end
end

local function bad(session: Session<any>)
    return session._.why_bad
end

local function add_userid<T>(session: Session<T>, user_id: number)
    if session._.finished then THROW("session_already_stopped") end
    table.insert(session._.user_ids, user_id)
end

local function loaded(session: Session<any>)
    return session._.first_request_succeeded
end

local function load_session<T>(self: Store<T>, key: string): Session<T>
    local session = {
        _ = {
            store = self,
            datastore = self._store,
            options = self._options,
            changes = {},
            pending_transactions = {},
            waiting_for_saved = {},
            next_save_opportunity = 0,
            updated = NOOP,
            user_ids = {},
            pull_delay = self._options.pull_delay or AUTOSAVE_DELAY,
            cached = {
                pending_transactions = {},
                migrations_performed = {},
                data = self._options.default_data()
            },
            first_request_succeeded = false,
            finished = false,
        },
        
        name = `{self._store.Name}:{key}`,
        key = key
    }

    session.patch = patch
    session.updated = updated
    session.stop = stop
    session.userid = add_userid
    session.loaded = loaded
    session.bad = bad
    session.await = await

    session._.thread = task.spawn(thread, session :: any)

    return session :: any
end

return {
    load_session = load_session,
    pull_auto = pull_auto,
    force_pull = force_pull,
    perform_transaction = perform_transaction,
    commit_transaction_early = commit_transaction_early
}
