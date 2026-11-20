///|
test "row plans clip window endpoints within a stripe" {
  let schema = Schema::new([{ name: "id", kind: Long, }])
  let batch = Batch::new(schema, [Array::makei(8, i => Integer(i.to_int64()))])
  let file = OrcFile::open(write(batch))
  let plan = file.plan_rows(2, 4, ["id"])
  assert_eq(plan.length(), 1)
  assert_eq(plan[0].first_row, 2)
  assert_eq(plan[0].row_count, 4)
  assert_eq(plan[0].streams, file.plan_stripe(0, ["id"]))
  assert_true(file.plan_rows(8, 0, ["id"]).is_empty())
}
