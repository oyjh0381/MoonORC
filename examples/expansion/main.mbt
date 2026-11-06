///|
fn main raise {
  let schema = @orc.Schema::new([
    { name: "id", kind: Long, },
    { name: "label", kind: String, },
  ])
  let batch = @orc.Batch::new(schema, [
    [Integer(9007199254740993L), Integer(2L), Integer(9007199254740993L)],
    [Text("first"), Text("second"), Text("retry")],
  ])
  let cleaned = batch
    .unique_rows(["id"])
    .sort_rows([{ column: "id", descending: false, nulls_first: false, }])
  assert_eq(cleaned.row_count(), 2)
  assert_eq(cleaned.cell(1, "label"), Text("first"))
  let roundtrip = @orc.OrcFile::open(@orc.write(cleaned)).read_stripe(0)
  assert_eq(roundtrip.cell(1, "id"), Integer(9007199254740993L))
  println(
    "Stable deduplication and typed ordering produce deterministic ORC exports with exact Int64 keys",
  )
}
