///|
test "microsecond conversion preserves pre-epoch values and both Int64 endpoints" {
  for
    us in [-9223372036854775808L, -1000001L, -1L, 0L, 1L, 9223372036854775807L] {
    assert_eq(TimestampValue::from_unix_micros(us).to_unix_micros(), us)
  }
  assert_eq(TimestampValue::from_unix_micros(-1L), {
    seconds: -1L,
    nanos: 999999000,
  })
}
