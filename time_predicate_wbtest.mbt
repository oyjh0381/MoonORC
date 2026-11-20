///|
test "timestamp windows use inclusive lower and exclusive upper boundaries" {
  let predicate = Predicate::timestamp_range(
    "stamp",
    { seconds: 1L, nanos: 0, },
    { seconds: 1L, nanos: 10, },
  )
  let schema = Schema::new([{ name: "stamp", kind: TimestampInstant, }])
  let input = Batch::new(schema, [
    [Time({ seconds: 1L, nanos: 0, }), Time({ seconds: 1L, nanos: 10, }), Null],
  ])
  predicate.validate(schema, 0, Ref(10))
  assert_true(predicate.evaluate(input, 0) is Yes)
  assert_true(predicate.evaluate(input, 1) is No)
  assert_true(predicate.evaluate(input, 2) is Unknown)
}
