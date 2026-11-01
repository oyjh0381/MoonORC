///|
fn main raise {
  let schema = @orc.Schema::new([
    { name: "id", kind: Long, },
    { name: "status", kind: String, },
  ])
  let batch = @orc.Batch::new(schema, [
    [Integer(10L), Integer(20L), Integer(30L)],
    [Text("ok"), Text("bad"), Text("ok")],
  ])
  let file = @orc.OrcFile::open(@orc.write(batch))
  let consumer = @orc.Schema::new([{ name: "status", kind: String, }])
  assert_true(file.schema().check_contract(consumer).compatible())
  let scan = file.scan(
    columns=Some(["status"]),
    predicate=Compare("id", Greater, Integer(10L)),
    batch_rows=1,
  )
  assert_eq(scan.next_positioned().unwrap().source_rows, [1])
  assert_eq(scan.next_positioned().unwrap().source_rows, [2])
  assert_true(scan.next_positioned() is None)
  println(
    "ORC consumer contract and source row evidence survive predicate filtering and column projection",
  )
}
