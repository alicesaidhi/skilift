export type Action<T=any, U...=...any> = (old: T, U...) -> T
export type JSON = string | number | boolean | buffer | { JSON } | { [string]: JSON }

export type StoreOptions<T> = {
    --- The name of the Data Store
    name: string,
    --- The scope of the Data Store
    scope: string?,
    --- The default data that will automatically be available.
    default_data: () -> T,
    --- Performs migrations in the given order. The version number is associated
    --- with the index. It's important not to change any of the migrations. 
    migrations: { {step: string, migrate: (any) -> (any)} },
}

export type Store<T> = {
    _store: DataStore,
    _options: StoreOptions<T>,

    --- Starts a new safe session that frequently polls for updates.
    load: (Store<T>, key: string) -> Session<T>,
    --- Returns a object used to gain insight into a key without polling for new
    --- data and applying updates.
    view: (Store<T>, key: string) -> View<T>
}

export type View<T> = {
    --- Pulls for the latest version and returns an immutable copy
    latest: (View<T>) -> T?,
    --- Pulls for a version at a given time.
    timestamp: (View<T>, at: number) -> T?,
    --- Pulls for a vesrion with the given key.
    version: (View<T>, version: string) -> T?,
}

export type Session<T> = {
    _name: string,
    _store: DataStore,
    _options: StoreOptions<T>,
    --- A list of changes that haven't been pushed yet.
    _changes: { Action },
    --- When the next refresh happens.
    _next_save_opportunity: number,
    --- Runs to reconcile the Datastores into the data.
    _updated: (T, UpdateType) -> (),
    --- The currently stored data.
    _cached: StoredData<T>,
    --- The thread responsible for autosaving.
    _thread: thread,
    --- Usere IDs for GDPR
    _user_ids: { number },

    key: string,

    --- Patches with the given update function. Fails if the data is locked.
    patch: <U...>(Session<T>, fn: Action<T, U...>, U...) -> (),
    --- Binds a function to whenever the session receives updated data.
    --- This should be reconciled into your own game state. When called, it will
    --- run the function given immediately.
    updated: (Session<T>, (T, UpdateType) -> ()) -> (),
    --- Stops polling the datastore for data, and disables any patching. This
    --- performs one more save. Releases the lock if it was locked.
    stop: (Session<T>) -> (),
    --- Adds a user id to the gdpr list.
    gdpr: (Session<T>, user_id: number) -> (),

    -- ---- SESSION LOCKING ADDENDUM ----
    -- --- Locks data. This should only be used in cases where session locking is
    -- --- required. When sesion locking, other servers are unable to edit the data.
    -- --- This may error.
    -- lock: (Session<T>, expires: number) -> (),
    -- --- Steals a session from another server (if necessary) 
    -- steal: (Session<T>) -> (),
    -- --- Unlocks the session, allowing other servers to edit the data.
    -- unlock: (Session<T>) -> (),
}

export type TransactionId = string

export type TransactionInfo = {
    uuid: TransactionId,
    state: "success" | "failure",
    sessions: { [Session<any>]: TransactionData },
}

export type TransactionAction = { fn: string, values: { JSON } }

--- Data stored in the key, containing information about transactions that
--- still need to be performed
export type TransactionData = {
    success: { TransactionAction },
    failure: { TransactionAction }
}

export type StoredData<T> = {
    pending_transactions: { [TransactionId]: TransactionData },
    migrations_performed: { string },
    data: T
}

export type UpdateType = "from_cache" | "default_data" | "from_source"

return {}