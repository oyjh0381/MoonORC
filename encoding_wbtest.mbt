///|
/// Independent MSB-first test packer; excluded from production encoding paths.
fn pack_test(values : Array[UInt64], width : Int32) -> Bytes {
  let bytes = Array::make((values.length() * width + 7) / 8, b'\x00')
  let mut bit = 0
  for value in values {
    for j = width - 1; j >= 0; j = j - 1 {
      if ((value >> j) & 1UL) != 0UL {
        bytes[bit / 8] = (bytes[bit / 8].to_int() | (1 << (7 - bit % 8))).to_byte()
      }
      bit += 1
    }
  }
  Bytes::from_array(bytes)
}

///|
test "every RLEv2 width decodes independent packed runs with both signs" {
  for code = 0; code < 32; code = code + 1 {
    let width = bit_width(code)
    let mask = if width == 64 {
      0xffffffffffffffffUL
    } else {
      (1UL << width) - 1UL
    }
    let values = Array::makei(17, i => (i.to_uint64() * 982451653UL) & mask)
    let stream = output()
    stream.byte(64 | (code << 1))
    stream.byte(16)
    stream.raw(pack_test(values, width))
    assert_eq(decode_rle2(stream.finish(), 17, false), values)
    assert_eq(
      decode_rle2(stream.finish(), 17, true),
      values.map(n => unzig(n).reinterpret_as_uint64()),
    )
  }
}

///|
test "byte RLE repeat and literal transitions cover length limits" {
  let run = b"\x7f\x42" // repeat 130 times
  assert_eq(decode_bytes(run, 130), Bytes::from_array(Array::make(130, b'B')))
  let one = b"\xff\x80"
  assert_eq(decode_bytes(one, 1), b"\x80")
  assert_true(
    try {
      ignore(decode_bytes(run, 129))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_bytes(one + b"\x00", 1))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "RLEv2 signed short-repeat and full-width direct use zigzag exactly" {
  assert_eq(decode_rle2(b"\x00\x01", 3, true), [
    0xffffffffffffffffUL, 0xffffffffffffffffUL, 0xffffffffffffffffUL,
  ])
  let bits = [0xffffffffffffffffUL, 0xfffffffffffffffeUL, 0UL]
  let stream = b"\x7e\x02" + pack_test(bits, 64)
  let decoded = decode_rle2(stream, 3, true)
  assert_eq(decoded[0].reinterpret_as_int64(), -9223372036854775808L)
  assert_eq(decoded[1].reinterpret_as_int64(), 9223372036854775807L)
}

///|
test "RLEv2 fixed negative delta and sign-magnitude patched base are separate" {
  assert_eq(
    decode_rle2(b"\xc0\x03\x0a\x03", 4, true).map(n => n.reinterpret_as_int64()),
    [5L, 3L, 1L, -1L],
  )
  // Four unsigned residuals [0,1,2,3] above base -10. No patches.
  let patched = b"\x82\x03\x00\x00\x8a\x1b"
  assert_eq(decode_rle2(patched, 4, true).map(n => n.reinterpret_as_int64()), [
    -10L, -9L, -8L, -7L,
  ])
}

///|
test "ORC compressed frames reject invalid size truncation and decoded bombs" {
  let limits = Limits::default()
  for raw in [b"\x00", b"\x00\x00\x00", b"\x05\x00\x00\x01"] {
    assert_true(
      try {
        ignore(decompress(raw, Zlib, 256, limits))
        false
      } catch {
        _ => true
      },
    )
  }
  let payload = Bytes::from_array(Array::make(1024, b'a'))
  let raw = compress(payload, Zlib, 1024)
  assert_true(
    try {
      ignore(decompress(raw, Zlib, 128, limits))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(decompress(b"\x07\x00\x00abc", Zlib, 64, limits), b"abc")
}

///|
test "IEEE floating wire payloads preserve negative zero infinity and double NaN bits" {
  let schema = Schema::new([
    { name: "f", kind: Float, },
    { name: "d", kind: Double, },
  ])
  let nan = 0x7ff8000000000001UL.reinterpret_as_double()
  let batch = Batch::new(schema, [
    [Real(-0.0), Real(1.25), Real(1.0 / 0.0)],
    [Real(nan), Null, Real(-0.0)],
  ])
  let file = OrcFile::open(write(batch))
  let decoded = file.read_stripe(0)
  guard decoded.cell(0, "f") is Real(zero) else { fail("float expected") }
  assert_eq(zero.reinterpret_as_uint64(), 0x8000000000000000UL)
  guard decoded.cell(0, "d") is Real(nan) else { fail("double expected") }
  assert_eq(nan.reinterpret_as_uint64(), 0x7ff8000000000001UL)
  guard decoded.cell(2, "f") is Real(infinity) else {
    fail("infinity expected")
  }
  assert_true(infinity.is_pos_inf())
}

///|
test "all-null primitive columns and empty text are distinct" {
  let kinds : Array[Kind] = [
    Boolean,
    Byte,
    Short,
    Int,
    Long,
    Float,
    Double,
    String,
    Binary,
    Date,
  ]
  let schema = Schema::new(kinds.map(k => { name: "c\{k.code()}", kind: k, }))
  let batch = Batch::new(schema, kinds.map(_ => [Null, Null]))
  let f = OrcFile::open(write(batch))
  let decoded = f.read_stripe(0)
  for column in schema.columns {
    assert_eq(decoded.column(column.name), [Null, Null])
  }
  assert_true(f.stripe_statistics(0).all(s => s.count == Some(0)))
}
