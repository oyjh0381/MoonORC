# MoonORC

Local prerelease of a pure MoonBit ORC columnar record library. Account and publication are intentionally unset (`private = true`).

The scope is flat, nullable, typed records, independent stripes, column projection, bounded primitive encodings and conservative statistics-based pruning. This is not HDF5 arrays, an in-memory DataFrame, a SQL engine, or an external sorting tool. Unsupported ORC features must fail explicitly.

Build with MoonBit 0.10.16 or compatible newer toolchains: `moon check`, `moon build`, `moon test`. Runnable scenarios and interoperability instructions will be added as verified. License: Apache-2.0. Reports and application material remain outside Git.
