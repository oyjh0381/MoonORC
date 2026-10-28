///|
/// Align two versions of an export contract before writing portable ORC.
fn main raise {
  let legacy_schema = @orc.Schema::new([
    { name: "id", kind: Long, },
    { name: "name", kind: String, },
  ])
  let current_schema = @orc.Schema::new([
    { name: "name", kind: String, },
    { name: "id", kind: Long, },
    { name: "active", kind: Boolean, },
  ])
  let old = @orc.Batch::new(legacy_schema, [
    [Integer(10L), Integer(11L)],
    [Text("alpha"), Text("beta")],
  ])
  let recent = @orc.Batch::new(current_schema, [
    [Text("gamma")],
    [Integer(12L)],
    [Bool(true)],
  ])
  let joined = @orc.concat([old.align(current_schema), recent])
  assert_eq(joined.cell(0, "active"), Null)
  let file = @orc.OrcFile::open(
    @orc.write(joined, metadata=Map([("contract", b"v2")])),
  )
  let scan = file.scan(columns=Some(["id", "active"]))
  let result = scan.next().unwrap()
  assert_eq(result.column("id"), [Integer(10L), Integer(11L), Integer(12L)])
  assert_eq(result.column("active"), [Null, Null, Bool(true)])
  assert_eq(file.user_metadata().get("contract"), Some(b"v2"))
  println(
    "ETL: name-based contract alignment, explicit null extension, and portable ORC verified",
  )
}
