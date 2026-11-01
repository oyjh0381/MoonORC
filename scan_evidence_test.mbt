///|
test "positioned scans retain source rows across stripes filters projections and pages" {
  let schema = @moonorc.Schema::new([
    { name: "id", kind: Long, },
    { name: "label", kind: String, },
  ])
  let batch = @moonorc.Batch::new(schema, [
    Array::makei(12, i => Integer(i.to_int64())),
    Array::makei(12, i => Text(i.to_string())),
  ])
  let file = @moonorc.OrcFile::open(
    @moonorc.write(batch, options={
      ..@moonorc.WriteOptions::default(),
      stripe_rows: 4,
    }),
  )
  let scan = file.scan(
    columns=Some(["label"]),
    predicate=Compare("id", GreaterEqual, Integer(5L)),
    row_start=3,
    row_count=Some(7),
    batch_rows=2,
  )
  let rows : Array[Int32] = []
  while scan.next_positioned() is Some(page) {
    for i, row in page.source_rows {
      assert_eq(page.batch.cell(i, "label"), Text(row.to_string()))
      rows.push(row)
    }
    page.source_rows.clear()
  }
  assert_eq(rows, [5, 6, 7, 8, 9])
  assert_eq(scan.metrics().rows_returned, 5)
}

///|
test "schema contracts report ordered missing type conflicts and tolerated extras" {
  let source = @moonorc.Schema::new([
    { name: "id", kind: Long, },
    { name: "extra", kind: String, },
  ])
  let contract = @moonorc.Schema::new([
    { name: "id", kind: Int, },
    { name: "when", kind: Date, },
  ])
  let result = source.check_contract(contract)
  assert_true(!result.compatible())
  assert_eq(result.incompatible, ["id"])
  assert_eq(result.missing, ["when"])
  assert_eq(result.extra, ["extra"])
  assert_true(
    source
    .check_contract(@moonorc.Schema::new([{ name: "id", kind: Long, }]))
    .compatible(),
  )
}

///|
test "positioned scanner skips empty stripes and can interleave ordinary reads" {
  let schema = @moonorc.Schema::new([{ name: "x", kind: Long, }])
  let batch = @moonorc.Batch::new(schema, [
    Array::makei(10, i => Integer(i.to_int64())),
  ])
  let file = @moonorc.OrcFile::open(
    @moonorc.write(batch, options={
      ..@moonorc.WriteOptions::default(),
      stripe_rows: 2,
    }),
  )
  let scan = file.scan(
    predicate=Compare("x", Greater, Integer(5L)),
    trust_statistics=true,
    batch_rows=1,
  )
  assert_eq(scan.next_positioned().unwrap().source_rows, [6])
  assert_eq(scan.next().unwrap().column("x"), [Integer(7L)])
  let page = scan.next_positioned().unwrap()
  assert_eq(page.source_rows, [8])
  page.source_rows[0] = 0
  assert_eq(scan.next_positioned().unwrap().source_rows, [9])
  assert_true(scan.next_positioned() is None)
  assert_eq(scan.metrics().rows_returned, 4)
}
