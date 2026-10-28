///|
/// Black-box test: public accessors must not leak mutable retained columns.
test "public schema and column accessors return defensive copies" {
  let columns : Array[@moonorc.Column] = [{ name: "x", kind: Long, }]
  let schema = @moonorc.Schema::new(columns)
  columns[0] = { name: "bad", kind: String, }
  let rows : Array[@moonorc.Cell] = [Integer(7L), Null]
  let batch = @moonorc.Batch::new(schema, [rows])
  rows[0] = Integer(9L)
  let copy = batch.column("x")
  copy[0] = Integer(10L)
  let names = schema.columns()
  names[0] = { name: "changed", kind: Boolean, }
  assert_eq(batch.cell(0, "x"), Integer(7L))
  let file = @moonorc.OrcFile::open(@moonorc.write(batch))
  let stripes = file.stripes()
  stripes.clear()
  assert_eq(file.stripes().length(), 1)
  assert_eq(file.read_stripe(0).cell(0, "x"), Integer(7L))
}
