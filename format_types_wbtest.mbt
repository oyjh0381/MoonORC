///|
test "decimal38 preserves exact coefficients, signs, scales and nulls in both codecs" {
  let schema = Schema::new([
    { name: "amount", kind: Decimal(38, 8), },
    { name: "code", kind: Varchar(4), },
    { name: "tag", kind: Char(3), },
  ])
  let amounts : Array[Cell] = [
    DecimalNumber(
      DecimalValue::parse("999999999999999999999999999999.99999999", 38, 8),
    ),
    DecimalNumber(
      DecimalValue::parse("-999999999999999999999999999999.99999999", 38, 8),
    ),
    Null,
    DecimalNumber(DecimalValue::parse("0", 38, 8)),
    DecimalNumber(DecimalValue::parse("-0.00000001", 38, 8)),
  ]
  let batch = Batch::new(schema, [
    amounts,
    [Text("你好😀"), Null, Text(""), Text("abcd"), Text("é")],
    [Text("中😀"), Text(""), Null, Text("xyz"), Text("a")],
  ])
  for codec in [None, Zlib] {
    let file = OrcFile::open(
      write(batch, options={
        ..WriteOptions::default(),
        compression: codec,
        stripe_rows: 2,
      }),
    )
    assert_eq(file.schema().columns(), schema.columns())
    let restored = concat(
      Array::makei(file.stripes().length(), i => file.read_stripe(i)),
    )
    assert_eq(restored.column("amount"), amounts)
    assert_eq(restored.column("code"), batch.column("code"))
    assert_eq(
      file
      .scan(
        columns=Some(["code"]),
        predicate=Compare(
          "amount",
          Less,
          DecimalNumber(DecimalValue::parse("0", 38, 8)),
        ),
      )
      .next()
      .unwrap()
      .column("code"),
      [Null],
    )
  }
  assert_eq(DecimalValue::parse("-000.00", 5, 2).to_string(), "0.00")
  assert_eq(
    compare_decimal(
      DecimalValue::parse("1.2", 3, 1),
      DecimalValue::parse("1.20", 3, 2),
    ),
    0,
  )
}

///|
test "character domains and decimal failures do not truncate or round" {
  for
    kind in [
      Decimal(0, 0),
      Decimal(39, 0),
      Decimal(3, 4),
      Char(0),
      Varchar(65536),
    ] {
    assert_true(
      try {
        ignore(Schema::new([{ name: "x", kind, }]))
        false
      } catch {
        _ => true
      },
    )
  }
  for text in ["", "1e2", "NaN", ".1", "1.", "1.001", "1000", "--1"] {
    assert_true(
      try {
        ignore(DecimalValue::parse(text, 3, 2))
        false
      } catch {
        _ => true
      },
    )
  }
  for kind in [Char(2), Varchar(2)] {
    let s = Schema::new([{ name: "x", kind, }])
    assert_true(
      try {
        ignore(Batch::new(s, [[Text("你好😀")]]))
        false
      } catch {
        _ => true
      },
    )
    assert_eq(Batch::new(s, [[Text("中😀")]]).row_count(), 1)
  }
  assert_true(
    try {
      ignore(
        Batch::new(Schema::new([{ name: "x", kind: Char(3), }]), [[Text("a ")]]),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        Batch::new(
          Schema::new([{ name: "x", kind: Char(65535), }]),
          [[Text("")]],
          limits={ ..Limits::default(), max_decoded_bytes: 100, },
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        Batch::new(Schema::new([{ name: "x", kind: Decimal(3, 1), }]), [
          [DecimalNumber(DecimalValue::parse("1.20", 3, 2))],
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_decimal(input(b"\x80"), 0L, 38, 0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_decimal(input(Bytes::make(20, b'\xff')), 0L, 38, 0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_decimal(input(b"\x02"), 1L, 38, 0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_decimal(input(b"\x02"), -39L, 38, 0))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "decimal varints match small independent zigzag and bounded large roundtrips" {
  for n = -1000; n <= 1000; n = n + 1 {
    let d = DecimalValue::parse(n.to_string(), 38, 0)
    let out = output()
    encode_decimal(d, out)
    let reference = output()
    reference.varint(zig(n.to_int64()))
    assert_eq(out.finish(), reference.finish())
    assert_eq(decode_decimal(input(out.finish()), 0L, 38, 0), d)
  }
  for scale = 0; scale <= 38; scale = scale + 1 {
    let d = decode_decimal(input(b"\x02"), scale.to_int64(), 38, scale)
    let out = output()
    encode_decimal(d, out)
    assert_eq(out.finish(), b"\x02")
  }
}
