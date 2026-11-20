///|
test "nanosecond shifts cross epoch and reject second overflow" {
  let zero : TimestampValue = { seconds: 0L, nanos: 0, }
  assert_eq(zero.shift_nanos(-1L), { seconds: -1L, nanos: 999999999, })
  assert_eq(zero.shift_nanos(-1L).shift_nanos(1L), zero)
  let max : TimestampValue = {
    seconds: 9223372036854775807L,
    nanos: 999999999,
  }
  let rejected = try {
    ignore(max.shift_nanos(1L))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
