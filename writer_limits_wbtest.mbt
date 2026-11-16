///|
test "ORC writer caps the encoded stripe footer and rolls back a late timestamp error" {
  let schema = Schema::new([
    { name: "id", kind: Long, },
    { name: "time", kind: TimestampInstant, },
  ])
  let options = { ..WriteOptions::default(), stripe_rows: 1, }
  let moment = Time({ seconds: 1L, nanos: 0, })
  let batch = Batch::new(schema, [[Integer(10L)], [moment]])
  let staged = output()
  let stripe = write_stripe(batch, staged, options, Limits::default())
  let narrow = { ..Limits::default(), max_file_bytes: stripe.data_bytes, }
  assert_true(
    try {
      ignore(write_stripe(batch, output(), options, narrow))
      false
    } catch {
      Limit("ORC stripe footer bytes") => true
      _ => false
    },
  )
  let writer = Writer::new(schema, options~)
  writer.push(batch)
  let unencodable = Time({ seconds: -1L, nanos: 500000000, })
  let failed = Batch::new(schema, [
    [Integer(20L), Integer(30L)],
    [moment, unencodable],
  ])
  assert_true(
    try {
      writer.push(failed)
      false
    } catch {
      Unsupported(_) => true
      _ => false
    },
  )
  assert_eq(writer.row_count(), 1)
  writer.push(Batch::new(schema, [[Integer(40L)], [moment]]))
  let file = OrcFile::open(writer.finish())
  assert_eq(file.stripes().length(), 2)
  assert_eq(file.read_stripe(1).cell(0, "id"), Integer(40L))
}
