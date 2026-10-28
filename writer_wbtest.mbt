///|
test "file serialization is deterministic across metadata map insertion order" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let batch = Batch::new(schema, [[Integer(9L), Null]])
  let a : Map[String, Bytes] = Map([("z", b"last"), ("a", b"first")])
  let b : Map[String, Bytes] = Map([("a", b"first"), ("z", b"last")])
  for compression in [None, Zlib] {
    let options = { ..WriteOptions::default(), compression, }
    let bytes = write(batch, options~, metadata=a)
    assert_eq(bytes, write(batch, options~, metadata=b))
    let writer = Writer::new(schema, options~)
    writer.push(batch)
    assert_eq(writer.finish(metadata=a), bytes)
    assert_eq(OrcFile::open(bytes).user_metadata().get("a"), Some(b"first"))
  }
}

///|
test "invalid writer configuration cannot create unbounded or non-progressing loops" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  for
    options in [
      { ..WriteOptions::default(), stripe_rows: 0, },
      { ..WriteOptions::default(), block_size: 0, },
      { ..WriteOptions::default(), block_size: 8388608, },
    ] {
    assert_true(
      try {
        ignore(Writer::new(schema, options~))
        false
      } catch {
        _ => true
      },
    )
  }
  let limits = { ..Limits::default(), max_columns: 0, }
  assert_true(
    try {
      ignore(Writer::new(schema, limits~))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "proleptic Gregorian date writing preserves raw days on both sides of reform" {
  let schema = Schema::new([{ name: "date", kind: Date, }])
  let values = [
    Days(-200000),
    Days(-141428),
    Days(-141427),
    Days(0),
    Days(30000),
    Null,
  ]
  let batch = Batch::new(schema, [values])
  let file = OrcFile::open(write(batch))
  assert_eq(file.read_stripe(0).column("date"), values)
  assert_eq(number(parse_proto(file.footer, file.limits), 11, 0UL), 2UL)
}
