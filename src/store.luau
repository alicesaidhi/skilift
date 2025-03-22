local actions = require("./actions")
local types = require("./types")
local view = require("./view")
local session = require("./session")
local flags = require("./flags")

type StoreOptions<T> = types.StoreOptions<T>
type Store<T> = types.Store<T>

-- local function add_action<T>(self: Store<T>, name, action)
--     if not action then action = name; name = nil end
--     if name then actions.register_transaction_action(self, action, name) else actions.register_action(self, action) end
--     return action
-- end

local function get_store<T>(options: StoreOptions<T>): Store<T>
    local store = {
        _options = options,
        _allowed_actions = {},
        _transaction_actions = {},
        _transaction_names = {},
        _store = flags.datastoreservice:GetDataStore(options.name, options.scope)
    }

    store.action = actions.register_action
    store.transaction = actions.register_transaction_action

    store.load = session.load_session
    store.view = view.view_key

    return store
end

return get_store