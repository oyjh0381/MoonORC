///|
fn small_file() -> Bytes raise OrcError {
  let schema = Schema::new([
    { name: "x", kind: Long, },
    { name: "s", kind: String, },
  ])
  write(
    Batch::new(schema, [
      [Integer(1L), Null, Integer(3L)],
      [Text("a"), Text("b"), Null],
    ]),
  )
}

///|
test "all truncated prefixes fail without partially returned rows" {
  let bytes = small_file()
  for n = 0; n < bytes.length(); n = n + 1 {
    assert_true(
      try {
        let f = OrcFile::open(bytes[:n].to_owned())
        ignore(f.read_stripe(0))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "invalid postscript length signature and unsupported version fail closed" {
  let bytes = small_file()
  for index in [0, 1, 2, bytes.length() - 1] {
    let bad = bytes.to_array()
    bad[index] = 0
    assert_true(
      try {
        ignore(OrcFile::open(Bytes::from_array(bad)))
        false
      } catch {
        _ => true
      },
    )
  }
  let ps = output()
  ps.field(1, 0UL)
  ps.message(4, b"\x01\x00")
  let bad = b"ORC" + ps.finish() + Bytes::from_array([ps.length().to_byte()])
  assert_true(
    try {
      ignore(OrcFile::open(bad))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "protobuf rejects malformed singular fields and unknown group encodings" {
  let limits = Limits::default()
  let fields = parse_proto(b"\x08\x01\x08\x02", limits)
  assert_true(
    try {
      ignore(number(fields, 1, 0UL))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parse_proto(b"\x0a\xff\xff\xff\xff\x7f", limits))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parse_proto(b"\x0b", limits))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parse_proto(b"\x08\x01\x10\x01", { ..limits, max_fields: 1, }))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "configured file row column and output budgets are enforced" {
  let bytes = small_file()
  assert_true(
    try {
      ignore(
        OrcFile::open(bytes, limits={
          ..Limits::default(),
          max_file_bytes: bytes.length() - 1,
        }),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(OrcFile::open(bytes, limits={ ..Limits::default(), max_rows: 2, }))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        OrcFile::open(bytes, limits={ ..Limits::default(), max_columns: 1, }),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        OrcFile::open(bytes, limits={
          ..Limits::default(),
          max_decoded_bytes: 1,
        }),
      )
      false
    } catch {
      _ => true
    },
  )
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let batch = Batch::new(schema, [[Integer(1L)]])
  assert_true(
    try {
      ignore(write(batch, limits={ ..Limits::default(), max_file_bytes: 4, }))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "RLE counts and trailing data cannot overflow a column allocation" {
  for raw in [b"\x7f\x00", b"\xff\x80", b"\x00\x80\x00"] {
    assert_true(
      try {
        ignore(decode_rle1(raw, 1, true))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(decode_rle2(b"\x00\x01", 2, true))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_bytes(b"\x00\x01", 2))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_bits(b"\xff\x80\x00", 1))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "signed delta arithmetic covers full range without intermediate signed overflow" {
  assert_eq(
    delta_value(0UL, 0x8000000000000000UL, true, true),
    0x8000000000000000UL,
  )
  assert_eq(
    delta_value(0x8000000000000000UL, 0xffffffffffffffffUL, false, true),
    0x7fffffffffffffffUL,
  )
  assert_true(
    try {
      ignore(delta_value(0UL, 0x8000000000000000UL, false, true))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "projection ignores an unselected malformed column stream" {
  let bytes = small_file()
  let file = OrcFile::open(bytes)
  let selected = file.plan_stripe(0, ["s"]).filter(s => s.kind == 2)[0]
  let bad = bytes.to_array()
  bad[selected.offset] = 127
  let malformed = OrcFile::open(Bytes::from_array(bad))
  assert_eq(
    malformed.read_stripe(0, columns=Some(["x"])).cell(0, "x"),
    Integer(1L),
  )
  assert_true(
    try {
      ignore(malformed.read_stripe(0))
      false
    } catch {
      _ => true
    },
  )
  let scan = malformed.scan(columns=Some(["x"]))
  assert_eq(scan.next().unwrap().row_count(), 3)
}

///|
test "empty nullable record files remain valid and scans terminate" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let batch = Batch::new(schema, [[]])
  for compression in [None, Zlib] {
    let file = OrcFile::open(
      write(batch, options={ ..WriteOptions::default(), compression, }),
    )
    assert_eq(file.row_count(), 0)
    assert_eq(file.stripes().length(), 0)
    assert_true(file.scan().next() is None)
  }
}
