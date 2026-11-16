///|
/// Whole Unix seconds and a nonnegative nanosecond fraction.
#derive(Debug, Eq)
pub(all) struct TimestampValue {
  seconds : Int64
  nanos : Int32
}

///|
pub extend TimestampValue with @debug.Debug::{to_repr}

///|
pub extend TimestampValue with Eq::{equal, not_equal}

///|
const ORC_EPOCH_SECONDS : Int64 = 1420070400L

///|
fn decode_timestamp(
  offset : Int64,
  wire : UInt64,
) -> TimestampValue raise OrcError {
  let mut nanos = wire >> 3
  let zeros = (wire & 7UL).to_int()
  if zeros != 0 {
    for _i = 0; _i <= zeros; _i = _i + 1 {
      if nanos > 99999999UL {
        raise Invalid("timestamp fraction exceeds one second", 0)
      }
      nanos *= 10UL
    }
  }
  if nanos >= 1000000000UL {
    raise Invalid("timestamp fraction exceeds one second", 0)
  }
  let seconds = signed_add(offset, ORC_EPOCH_SECONDS)
  // Apache ORC stores negative seconds with millisecond-or-larger fractions
  // using truncation toward zero, then restores floor seconds when reading.
  let seconds = if seconds < 0L && nanos > 999999UL {
    signed_add(seconds, -1L)
  } else {
    seconds
  }
  { seconds, nanos: nanos.to_int(), }
}

///|
fn encode_timestamp(value : TimestampValue) -> (Int64, UInt64) raise OrcError {
  let mut seconds = value.seconds
  if seconds < 0L && value.nanos > 999999 {
    if seconds == -1L {
      raise Unsupported(
        "ambiguous ORC timestamp in the fractional second before Unix epoch",
      )
    }
    seconds += 1L
  }
  let offset = signed_add(seconds, -ORC_EPOCH_SECONDS)
  let mut nanos = value.nanos.to_uint64()
  let mut zeros = 0
  if nanos != 0UL && nanos % 100UL == 0UL {
    nanos /= 100UL
    zeros = 1
    while nanos % 10UL == 0UL && zeros < 7 {
      nanos /= 10UL
      zeros += 1
    }
  }
  (offset, (nanos << 3) | zeros.to_uint64())
}
