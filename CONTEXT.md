# Columnar record interchange

ORC stores a table as independently encoded groups of rows. MoonORC exchanges and scans bounded ORC records rather than multidimensional arrays.

## Language

**Stripe**: A contiguous group of complete rows with its own column streams and footer.
_Avoid_: Array chunk, row group

**Column stream**: An encoded sequence for one aspect of a column, such as non-null flags, values or string lengths.
_Avoid_: Row buffer

**Projection**: The requested ordered subset of record fields.
_Avoid_: Filter

**Pruning**: Proving that a stripe cannot contain a matching row from its metadata.
_Avoid_: Matching, authentication

**Predicate**: A condition evaluated over a record, with explicit null semantics.
_Avoid_: Query language

**Batch**: An immutable set of equally sized typed nullable columns.
_Avoid_: Dataset when referring to one scan result
