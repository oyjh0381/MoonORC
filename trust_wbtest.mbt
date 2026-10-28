///| Forge validly framed statistics, demonstrating that ORC metadata is not

///|
/// authenticated. Default scans must not trust its claimed empty population.
test "untrusted forged statistics cannot suppress actual rows by default" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let batch = Batch::new(schema, [[Integer(1L), Integer(2L)]])
  let original = OrcFile::open(write(batch))
  let last = original.stripes[0]
  let content_end = last.offset +
    last.index_bytes +
    last.data_bytes +
    last.footer_bytes
  let fake_column = output()
  fake_column.field(1, 0UL)
  fake_column.field(10, 1UL)
  let stats = output()
  stats.message(1, b"")
  stats.message(1, fake_column.finish())
  let metadata = output()
  metadata.message(1, stats.finish())
  let ps = output()
  ps.field(1, original.footer.length().to_uint64())
  ps.field(2, 0UL)
  ps.field(3, 262144UL)
  ps.message(4, b"\x00\x0c")
  ps.field(5, metadata.length().to_uint64())
  ps.message(8000, b"ORC")
  let bytes = original.bytes[:content_end].to_owned() +
    metadata.finish() +
    original.footer +
    ps.finish() +
    Bytes::from_array([ps.length().to_byte()])
  let file = OrcFile::open(bytes)
  let predicate : Predicate = Compare("x", Equal, Integer(2L))
  let safe = file.scan(predicate~)
  assert_eq(safe.next().unwrap().column("x"), [Integer(2L)])
  let trusting = file.scan(predicate~, trust_statistics=true)
  assert_true(trusting.next() is None)
  assert_eq(trusting.metrics().stripes_skipped, 1)
}

///|
test "failed incremental push caused by row ceiling preserves prior output" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let limits = { ..Limits::default(), max_rows: 3, }
  let writer = Writer::new(schema, limits~, options={
    ..WriteOptions::default(),
    stripe_rows: 3,
  })
  writer.push(Batch::new(schema, [[Integer(1L), Integer(2L)]]))
  assert_true(
    try {
      writer.push(Batch::new(schema, [[Integer(3L), Integer(4L)]]))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(writer.row_count(), 2)
  let file = OrcFile::open(writer.finish())
  assert_eq(file.read_stripe(0).column("x"), [Integer(1L), Integer(2L)])
}
