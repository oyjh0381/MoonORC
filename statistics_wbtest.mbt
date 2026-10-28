///|
test "external statistics pruning agrees with exact scan when explicitly trusted" {
  for raw in [fixture_plain(), fixture_zlib()] {
    let file = OrcFile::open(raw)
    for
      predicate in [
        Compare("id", Greater, Integer(100000L)),
        Compare("label", Equal, Text("absent-value")),
        And(IsNull("id"), Compare("day", LessEqual, Days(20))),
        Not(Compare("id", Less, Integer(50L))),
      ] {
      let trusted = file.scan(predicate~, trust_statistics=true)
      let plain = file.scan(predicate~)
      let mut a = 0
      let mut b = 0
      while trusted.next() is Some(part) {
        a += part.rows
      }
      while plain.next() is Some(part) {
        b += part.rows
      }
      assert_eq(a, b)
    }
  }
}

///|
test "missing and partial statistics remain conservative" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let missing : Statistics = {
    count: None,
    has_null: None,
    minimum: None,
    maximum: None,
  }
  assert_true(IsNull("x").may_match(schema, [missing], 10))
  assert_true(Compare("x", Equal, Integer(1L)).may_match(schema, [missing], 10))
  let only_low = { ..missing, minimum: Some(Integer(5L)), }
  assert_true(
    !Compare("x", Less, Integer(4L)).may_match(schema, [only_low], 10),
  )
  assert_true(
    Compare("x", Greater, Integer(50L)).may_match(schema, [only_low], 10),
  )
}

///|
test "statistics malformed counts flags and reversed bounds fail explicitly" {
  let stats = output()
  stats.field(1, 11UL)
  assert_true(
    try {
      ignore(decode_statistics(stats.finish(), Long, 10, Limits::default()))
      false
    } catch {
      _ => true
    },
  )
  let bounds = output()
  bounds.field(1, zig(9L))
  bounds.field(2, zig(1L))
  let stats = output()
  stats.message(2, bounds.finish())
  assert_true(
    try {
      ignore(decode_statistics(stats.finish(), Long, 10, Limits::default()))
      false
    } catch {
      _ => true
    },
  )
}
