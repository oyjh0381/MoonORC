///|
test "timestamp seconds and fractional scaling round trip independently of byte streams" {
  for sec in [-10000L, -2L, 0L, 1420070400L, 2000000000L] {
    for nanos in [0, 1, 100, 999999, 1000000, 123456789, 999999999] {
      let value : TimestampValue = { seconds: sec, nanos, }
      let (offset, wire) = encode_timestamp(value)
      assert_eq(decode_timestamp(offset, wire), value)
    }
  }
  assert_eq(
    encode_timestamp({ seconds: 1420070400L, nanos: 1000, }),
    (0L, 10UL),
  )
  assert_true(
    try {
      ignore(decode_timestamp(0L, 8000000000UL))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(encode_timestamp({ seconds: -1L, nanos: 500000000, }))
      false
    } catch {
      _ => true
    },
  )
}
