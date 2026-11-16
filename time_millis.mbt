///|
/// Convert epoch milliseconds into whole seconds and a nonnegative fraction.
pub fn TimestampValue::from_unix_millis(ms : Int64) -> TimestampValue {
  let seconds = ms / 1000L
  let remainder = ms % 1000L
  if remainder < 0L {
    { seconds: seconds - 1L, nanos: (remainder.to_int() + 1000) * 1000000, }
  } else {
    { seconds, nanos: remainder.to_int() * 1000000, }
  }
}

///|
/// Convert to milliseconds only if the timestamp is exact and fits Int64.
pub fn TimestampValue::to_unix_millis(
  self : TimestampValue,
) -> Int64 raise OrcError {
  if self.nanos < 0 || self.nanos >= 1000000000 || self.nanos % 1000000 != 0 {
    raise Invalid("timestamp is not an exact millisecond", 0)
  }
  let low = TimestampValue::from_unix_millis(-9223372036854775808L)
  let high = TimestampValue::from_unix_millis(9223372036854775807L)
  if self.seconds < low.seconds ||
    self.seconds > high.seconds ||
    (self.seconds == low.seconds && self.nanos < low.nanos) ||
    (self.seconds == high.seconds && self.nanos > high.nanos) {
    raise Limit("epoch milliseconds exceed Int64")
  }
  let fraction = (self.nanos / 1000000).to_int64()
  if self.seconds < 0L {
    (self.seconds + 1L) * 1000L + (fraction - 1000L)
  } else {
    self.seconds * 1000L + fraction
  }
}

///|
test "exact milliseconds survive negative seconds and Int64 extrema" {
  assert_eq(TimestampValue::from_unix_millis(-1L), {
    seconds: -1L,
    nanos: 999000000,
  })
  for
    ms in [
      -9223372036854775808L, -1001L, -1000L, -1L, 0L, 1001L, 9223372036854775807L,
    ] {
    assert_eq(TimestampValue::from_unix_millis(ms).to_unix_millis(), ms)
  }
  let exact : TimestampValue = { seconds: 1L, nanos: 1, }
  assert_true(
    try {
      ignore(exact.to_unix_millis())
      false
    } catch {
      _ => true
    },
  )
}
