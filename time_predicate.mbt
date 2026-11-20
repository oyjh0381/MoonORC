///|
/// Build a half-open range matching timestamp cells of either ORC timestamp kind.
pub fn Predicate::timestamp_range(
  name : String,
  start : TimestampValue,
  end : TimestampValue,
) -> Predicate raise OrcError {
  if start.nanos < 0 ||
    start.nanos >= 1000000000 ||
    end.nanos < 0 ||
    end.nanos >= 1000000000 ||
    start.seconds > end.seconds ||
    (start.seconds == end.seconds && start.nanos > end.nanos) {
    raise Invalid("timestamp predicate range", 0)
  }
  And(Compare(name, GreaterEqual, Time(start)), Compare(name, Less, Time(end)))
}
