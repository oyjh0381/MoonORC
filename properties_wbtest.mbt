///|
test "signed integer widths nullable masks and stripe sizes agree for generated records" {
  let schema = Schema::new([{ name: "x", kind: Long }, { name: "s", kind: String }, { name: "p", kind: Boolean }])
  for rows in [0, 1, 2, 7, 127, 128, 129, 511] {
    let a = Array::makei(rows, i => if i % 5 == 0 { Null } else { Integer((i * i - 711).to_int64()) })
    let b = Array::makei(rows, i => if i % 11 == 0 { Null } else { Text(["", "x", "你好"][i % 3]) })
    let c = Array::makei(rows, i => if i % 9 == 0 { Null } else { Bool(i % 2 == 0) })
    let batch = Batch::new(schema, [a, b, c])
    for stripe_rows in [1, 7, 128] {
      for compression in [None, Zlib] {
        let bytes = write(batch, options={ compression, stripe_rows, block_size: 256 })
        let file = OrcFile::open(bytes)
        let scan = file.scan(columns=Some(["s", "x"]), batch_rows=17)
        let mut at = 0
        while scan.next() is Some(part) {
          for i = 0; i < part.rows; i = i + 1 {
            assert_eq(part.cell(i, "x"), a[at + i])
            assert_eq(part.cell(i, "s"), b[at + i])
          }
          at += part.rows
        }
        assert_eq(at, rows)
      }
    }
  }
}
///|
test "statistics pruning has no false negatives over exhaustive small integer cases" {
  let schema = Schema::new([{ name: "x", kind: Long }])
  for low = -3; low <= 2; low = low + 1 {
    for high = low; high <= 3; high = high + 1 {
      let values = [Null, Integer(low.to_int64()), Integer(high.to_int64())]
      let batch = Batch::new(schema, [values])
      let stats = [summarize(values)]
      for pivot = -4; pivot <= 4; pivot = pivot + 1 {
        for comparison in [Equal, Less, LessEqual, Greater, GreaterEqual] {
          let predicate : Predicate = Compare("x", comparison, Integer(pivot.to_int64()))
          let filtered = batch.filter(predicate)
          if filtered.row_count() > 0 { assert_true(predicate.may_match(schema, stats, 3)) }
          let absent : Statistics = { count: None, has_null: None, minimum: None, maximum: None }
          assert_true(predicate.may_match(schema, [absent], 3))
        }
      }
    }
  }
}
///|
test "projection filter columns can differ and input projection arrays are copied" {
  let schema = Schema::new([{ name: "id", kind: Long }, { name: "label", kind: String }])
  let file = OrcFile::open(write(Batch::new(schema, [[Integer(1L), Integer(9L)], [Text("a"), Text("b")]])))
  let names = ["label"]
  let scan = file.scan(columns=Some(names), predicate=Compare("id", Greater, Integer(5L)))
  names[0] = "missing"
  let result = scan.next().unwrap()
  assert_eq(result.schema.columns.length(), 1)
  assert_eq(result.cell(0, "label"), Text("b"))
}
///|
test "null comparisons three-valued AND OR and NOT are stable" {
  let schema = Schema::new([{ name: "x", kind: Long }])
  let batch = Batch::new(schema, [[Null, Integer(1L)]])
  let unknown : Predicate = Compare("x", Equal, Null)
  assert_eq(batch.filter(unknown).rows, 0)
  assert_eq(batch.filter(Not(unknown)).rows, 0)
  assert_eq(batch.filter(Or(unknown, Always(true))).rows, 2)
  assert_eq(batch.filter(And(unknown, Always(false))).rows, 0)
  assert_eq(batch.filter(Not(IsNull("x"))).rows, 1)
}
///|
test "scanner failures are latched instead of silently skipping bad stripes" {
  let file = OrcFile::open(small_file())
  let stream = file.plan_stripe(0, ["s"]).filter(s => s.kind == 2)[0]
  let raw = file.bytes.to_array()
  raw[stream.offset] = 127
  let scan = OrcFile::open(Bytes::from_array(raw)).scan()
  assert_true(try { ignore(scan.next()); false } catch { _ => true })
  assert_true(try { ignore(scan.next()); false } catch { _ => true })
  assert_eq(scan.metrics().rows_returned, 0)
}
///|
test "incompatible aliases and schema alignment never coerce values" {
  let schema = Schema::new([{ name: "x", kind: Long }])
  let batch = Batch::new(schema, [[Integer(5L)]])
  assert_true(try { ignore(batch.align(Schema::new([{ name: "x", kind: Double }]))); false } catch { _ => true })
  assert_true(try { ignore(batch.project(["x", "x"])); false } catch { _ => true })
  assert_true(try { ignore(batch.take([-1])); false } catch { _ => true })
  assert_true(try { ignore(concat([])); false } catch { _ => true })
}
