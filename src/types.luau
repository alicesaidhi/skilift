export type Action<T=any, U...=...any> = (old: T, U...) -> T
export type JSON = string | number | boolean | buffer | { JSON } | { [string]: JSON }

export type WhyBad = 
    --- A transaction used on the session cannot be recognized. This is likely
    --- because the server is outdated, or developer error.
    | "unrecognized_transaction"
    --- The data cannot be loaded. This is likely because you're trying to load a
    --- key that doesn't match the expected data format.
    | "cannot_load"
    --- The data has a migration that is unknown to this server. This is likely
    --- because the server is outdated, or developer error.
    | "unknown_migration"

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
    --- Allows you to change the delay before a session pulls data again.
    pull_delay: number?,
    --- A schema that would be validated against every patch
    schema: ((unknown) -> boolean)?,
}

export type Store<T> = {
    _store: DataStore,
    _options: StoreOptions<T>,
    _allowed_actions: { [(T) -> T]: true },
    _transaction_actions: { [(T) -> T]: string },
    _transaction_names: { [string]: (T) -> T },

    --- Action
    action: <U...>(Store<T>, action: Action<T, U...>) -> Action<T, U...>,
    transaction: <U...>(Store<T>, name: string, action: Action<T, U...>) -> Action<T, U...>,
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

export type Connection = {
    wait: (Connection) -> ()
}

export type Session<T> = {
    _: {
        store: Store<T>,
        datastore: DataStore,
        options: StoreOptions<T>,
        --- A list of changes that haven't been pushed yet.
        changes: { { Action & any } },
        --- When the next refresh happens.
        next_save_opportunity: number,
        --- Runs to reconcile the Datastores into the data.
        updated: (T) -> (),
        --- The currently stored data.
        cached: StoredData<T>,
        --- The thread responsible for autosaving.
        thread: thread,
        --- Threads waiting to resume
        waiting_for_saved: { () -> () },
        --- A reason why the session is not loaded properly
        why_bad: string?,
        --- User IDs for GDPR
        user_ids: { number },
        --- Indicates if a request has succeeded
        first_request_succeeded: boolean,
        --- The delay between a pull
        pull_delay: number,
        --- Indicates the state it's currently in.
        finished: false | "saving" | "done",
    },

    name: string,
    key: string,

    --- Patches with the given update function. Fails if the data is locked.
    patch: <U...>(Session<T>, fn: Action<T, U...>, U...) -> (),
    --- Binds a function to whenever the session receives updated data.
    --- This should be reconciled into your own game state. When called, it will
    --- run the function given immediately.
    updated: (Session<T>, (T) -> ()) -> (),
    --- Stops polling the datastore for data, and disables any patching. This
    --- performs one more save. Releases the lock if it was locked.
    stop: (Session<T>) -> (),
    --- Adds a user id to the gdpr list.
    userid: (Session<T>, user_id: number) -> (),
    --- Returns if the state has loaded
    loaded: (Session<T>) -> boolean,
    --- Returns an error code if the session is considered "bad".
    bad: (Session<T>) -> WhyBad?,
    --- Yields until the next pull happens
    await: (Session<T>) -> (),

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

return {}