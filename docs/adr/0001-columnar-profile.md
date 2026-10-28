# A bounded ORC profile, not another general data container

Implement actual ORC stripe/column encodings and selective record scanning, independently of the local HDF5 array library. Flat primitive records are the initial schema boundary; nested collections, decimals, timestamps, encryption and remote storage are rejected. Runtime behavior is tested against Apache ORC through pyorc; Python is not a runtime dependency.
