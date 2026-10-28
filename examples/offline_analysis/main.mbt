///|
/// A browser/desktop analytics component scans only needed measurement fields.
fn main raise {
  let schema = @orc.Schema::new([
    { name: "day", kind: Date, },
    { name: "station", kind: String, },
    { name: "value", kind: Double, },
    { name: "valid", kind: Boolean, },
  ])
  let source = @orc.Batch::new(schema, [
    [Days(20000), Days(20001), Days(20002), Days(20003)],
    [Text("north"), Text("north"), Text("south"), Text("north")],
    [Real(10.0), Real(20.0), Real(80.0), Null],
    [Bool(true), Bool(true), Bool(false), Null],
  ])
  let file = @orc.OrcFile::open(
    @orc.write(source, options={
      ..@orc.WriteOptions::default(),
      compression: Zlib,
    }),
  )
  let predicate : @orc.Predicate = And(
    Compare("station", Equal, Text("north")),
    Compare("valid", Equal, Bool(true)),
  )
  let scan = file.scan(columns=Some(["day", "value"]), predicate~)
  let batch = scan.next().unwrap()
  assert_eq(batch.row_count(), 2)
  assert_eq(batch.cell(1, "day"), Days(20001))
  let total = batch
    .column("value")
    .fold(init=0.0, (sum, v) => {
      match v {
        Real(n) => sum + n
        _ => sum
      }
    })
  assert_eq(total, 30.0)
  assert_eq(
    file
    .plan_stripe(0, ["day", "value"])
    .all(r => r.column == "day" || r.column == "value"),
    true,
  )
  println(
    "offline analytics: projected date/value columns and exact validity filtering verified",
  )
}
