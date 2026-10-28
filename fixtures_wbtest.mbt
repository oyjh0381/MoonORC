///| Independent Apache ORC writes these fixtures via pyorc, not this writer.
test "Apache ORC nullable primitive dictionaries and RLEv2 decode on every target" {
  for bytes in [fixture_plain(), fixture_zlib()] {
    let file = OrcFile::open(bytes)
    assert_eq(file.row_count(), 600)
    let scan = file.scan(batch_rows=53)
    let mut at = 0
    while scan.next() is Some(batch) {
      for r = 0; r < batch.rows; r = r + 1 {
        let i = at + r
        assert_eq(batch.cell(r, "id"), if i % 11 == 0 { Null } else { Integer((i - 300).to_int64()) })
        assert_eq(batch.cell(r, "label"), if i % 17 == 0 { Null } else { Text(["hello", "你好", "", "same"][i % 4]) })
        assert_eq(batch.cell(r, "small"), Integer((i % 256 - 128).to_int64()))
        assert_eq(batch.cell(r, "day"), Days(i - 300))
        assert_eq(batch.cell(r, "ratio"), Real(i.to_double() * 0.5))
      }
      at += batch.rows
    }
    assert_eq(at, 600)
    assert_eq(file.user_metadata().get("source"), Some(b"original-pyorc-fixture"))
    assert_true(file.row_groups(0, "id").length() > 0)
  }
}
///|
test "Apache ORC integer extremes and irregular values retain every bit" {
  let file = OrcFile::open(fixture_extreme())
  let batch = file.read_stripe(0)
  assert_eq(batch.cell(0, "x"), Integer(-9223372036854775808L))
  assert_eq(batch.cell(1, "x"), Integer(9223372036854775807L))
  assert_eq(batch.cell(2, "x"), Null)
  assert_eq(batch.cell(16, "x"), Integer(1002000L))
  assert_eq(batch.cell(0, "s"), Text("\u{10000}"))
  assert_eq(batch.cell(0, "f"), Real(-0.0))
}
///|
test "unsupported nested records fail at schema boundary not as guessed primitives" {
  assert_true(try { ignore(OrcFile::open(fixture_nested())); false } catch { _ => true })
}
