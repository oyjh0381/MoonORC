///|
test "stable ordering preserves Int64 precision, null policy and ties" {
  let b = Batch::new(
    Schema::new([{ name: "id", kind: Long, }, { name: "name", kind: String, }]),
    [
      [
        Integer(9007199254740993L),
        Null,
        Integer(9007199254740992L),
        Integer(9007199254740993L),
      ],
      [Text("first"), Text("null"), Text("low"), Text("second")],
    ],
  )
  let sorted = b.sort_rows([
    { column: "id", descending: false, nulls_first: false, },
  ])
  assert_eq(sorted.column("name"), [
    Text("low"),
    Text("first"),
    Text("second"),
    Text("null"),
  ])
  assert_eq(
    b
    .sort_rows([
      { column: "id", descending: true, nulls_first: true, },
      { column: "name", descending: true, nulls_first: false, },
    ])
    .column("name"),
    [Text("null"), Text("second"), Text("first"), Text("low")],
  )
  assert_eq(b.cell(0, "id"), Integer(9007199254740993L))
  assert_true(
    try {
      ignore(b.sort_rows([]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        b.sort_rows([
          { column: "absent", descending: false, nulls_first: false, },
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        b.sort_rows(
          [{ column: "id", descending: false, nulls_first: false, }],
          limits={ ..Limits::default(), max_rows: 1, },
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "unique keys use exact bits and framed text while preserving first rows" {
  let nan = 9221120237041090561UL.reinterpret_as_double()
  let nan2 = 9221120237041090562UL.reinterpret_as_double()
  let b = Batch::new(Schema::new([{ name: "v", kind: Double, }]), [
    [Real(0.0), Real(-0.0), Real(nan), Real(nan), Real(nan2), Null, Null],
  ])
  assert_eq(b.unique_rows(["v"]).row_count(), 5)
  let sorted = b.sort_rows([
    { column: "v", descending: false, nulls_first: false, },
  ])
  assert_eq(sorted.cell(6, "v"), Null)
  let text = Batch::new(
    Schema::new([{ name: "a", kind: String, }, { name: "b", kind: String, }]),
    [[Text("ab"), Text("a"), Text("ab")], [Text("c"), Text("bc"), Text("c")]],
  )
  assert_eq(text.unique_rows(["a", "b"]).row_count(), 2)
  assert_true(
    try {
      ignore(text.unique_rows(["a", "a"]))
      false
    } catch {
      _ => true
    },
  )
  let blobs = Batch::new(Schema::new([{ name: "x", kind: Binary, }]), [
    [Blob(b"\x01\x02"), Blob(b"\x0c"), Blob(b"\x01\x02")],
  ])
  assert_eq(blobs.unique_rows(["x"]).row_count(), 2)
  assert_true(
    try {
      ignore(
        blobs.sort_rows([
          { column: "x", descending: false, nulls_first: false, },
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        text.unique_rows(["a", "b"], limits={
          ..Limits::default(),
          max_decoded_bytes: 1,
        }),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "multi-key ordering and first occurrence dedup scale with repeated keys" {
  let count = 2048
  let schema = Schema::new([
    { name: "group", kind: Long, },
    { name: "ordinal", kind: Long, },
  ])
  let b = Batch::new(schema, [
    Array::makei(count, i => Integer((i % 128).to_int64())),
    Array::makei(count, i => Integer(i.to_int64())),
  ])
  let sorted = b.sort_rows([
    { column: "group", descending: true, nulls_first: false, },
    { column: "ordinal", descending: false, nulls_first: false, },
  ])
  for i = 0; i < count; i = i + 1 {
    assert_eq(sorted.cell(i, "group"), Integer((127 - i / 16).to_int64()))
    assert_eq(
      sorted.cell(i, "ordinal"),
      Integer((127 - i / 16 + i % 16 * 128).to_int64()),
    )
  }
  let distinct = b.unique_rows(["group"])
  assert_eq(distinct.row_count(), 128)
  for i = 0; i < 128; i = i + 1 {
    assert_eq(distinct.cell(i, "ordinal"), Integer(i.to_int64()))
  }
}
