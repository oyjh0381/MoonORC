///|
/// Add a signed nanosecond offset and normalize the fractional component.
pub fn TimestampValue::shift_nanos(
  self : TimestampValue,
  delta : Int64,
) -> TimestampValue raise OrcError {
  if self.nanos < 0 || self.nanos >= 1000000000 {
    raise Invalid("timestamp fraction", 0)
  }
  let mut whole = delta / 1000000000L
  let mut fraction = self.nanos.to_int64() + delta % 1000000000L
  if fraction < 0L {
    whole -= 1L
    fraction += 1000000000L
  } else if fraction >= 1000000000L {
    whole += 1L
    fraction -= 1000000000L
  }
  { seconds: signed_add(self.seconds, whole), nanos: fraction.to_int(), }
}
