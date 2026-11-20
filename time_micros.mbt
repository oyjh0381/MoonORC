///|
pub fn TimestampValue::from_unix_micros(us : Int64) -> TimestampValue {
  let seconds = us / 1000000L
  let remainder = us % 1000000L
  if remainder < 0L {
    { seconds: seconds - 1L, nanos: (remainder.to_int() + 1000000) * 1000, }
  } else {
    { seconds, nanos: remainder.to_int() * 1000, }
  }
}

///|
pub fn TimestampValue::to_unix_micros(
  self : TimestampValue,
) -> Int64 raise OrcError {
  if self.nanos < 0 || self.nanos >= 1000000000 || self.nanos % 1000 != 0 {
    raise Invalid("timestamp is not an exact microsecond", 0)
  }
  let low = TimestampValue::from_unix_micros(-9223372036854775808L)
  let high = TimestampValue::from_unix_micros(9223372036854775807L)
  if self.seconds < low.seconds ||
    self.seconds > high.seconds ||
    (self.seconds == low.seconds && self.nanos < low.nanos) ||
    (self.seconds == high.seconds && self.nanos > high.nanos) {
    raise Limit("epoch microseconds exceed Int64")
  }
  let fraction = (self.nanos / 1000).to_int64()
  if self.seconds < 0L {
    (self.seconds + 1L) * 1000000L + (fraction - 1000000L)
  } else {
    self.seconds * 1000000L + fraction
  }
}
