///|
test "source row ranges precede predicates and cross stripe boundaries exactly" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let batch = Batch::new(schema, [Array::makei(30, i => Integer(i.to_int64()))])
  let file = OrcFile::open(
    write(batch, options={ ..WriteOptions::default(), stripe_rows: 7, }),
  )
  for start = 0; start <= 30; start = start + 1 {
    for count = 0; count <= 30 - start; count = count + 1 {
      let scan = file.scan(row_start=start, row_count=Some(count), batch_rows=3)
      let actual : Array[Cell] = []
      while scan.next() is Some(b) {
        actual.append(b.column("x"))
      }
      assert_eq(actual, batch.column("x")[start:start + count].to_owned())
    }
  }
  let scan = file.scan(
    row_start=5,
    row_count=Some(8),
    predicate=Compare("x", GreaterEqual, Integer(10L)),
  )
  assert_eq(scan.next().unwrap().column("x"), [
    Integer(10L),
    Integer(11L),
    Integer(12L),
  ])
  assert_true(scan.next() is None)
}

///|
test "row range exclusion needs no trust in statistics" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let file = OrcFile::open(
    write(Batch::new(schema, [Array::makei(12, i => Integer(i.to_int64()))]), options={
      ..WriteOptions::default(),
      stripe_rows: 3,
    }),
  )
  let scan = file.scan(row_start=3, row_count=Some(3))
  assert_eq(scan.next().unwrap().column("x"), [
    Integer(3L),
    Integer(4L),
    Integer(5L),
  ])
  assert_true(scan.next() is None)
  assert_eq(scan.metrics().stripes_read, 1)
  assert_eq(scan.metrics().stripes_skipped, 3)
  assert_true(
    try {
      ignore(file.scan(row_start=13))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(file.scan(row_start=11, row_count=Some(2)))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "incremental writers cannot mutate input and failed finish preserves staged stripes" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let options = { ..WriteOptions::default(), stripe_rows: 3, }
  let writer = Writer::new(schema, options~, limits={
    ..Limits::default(),
    max_file_bytes: 300,
  })
  writer.push(Batch::new(schema, [[Integer(1L), Integer(2L)]]))
  let metadata : Map[String, Bytes] = Map([
    ("large", Bytes::from_array(Array::make(400, b'a'))),
  ])
  assert_true(
    try {
      ignore(writer.finish(metadata~))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(writer.row_count(), 2)
  let file = OrcFile::open(writer.finish())
  assert_eq(file.read_stripe(0).column("x"), [Integer(1L), Integer(2L)])
}
