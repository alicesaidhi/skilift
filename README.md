
> [!CAUTION]
> Skilift is no longer maintained, and further usage of skilift is no longer recommended. Skilift for a while has not been my goto for my projects due to a less than ideal API and certain design issues which cannot be remedied. 
> Session locks are from my experience more practical to work with, especially if the datastore does not act as your source of truth. The reasons mentioned above have all thus led to the decision to no longer maintain and archive skilift.

# Skilift

Skilift is a modern lockless data storage library with transactions. It does not use session locks, guaranteeing that players will be able to access their data aslong as DataStoreService is available.


[Documentation](https://alicesaidhi.github.io/skilift/)
