///|
pub fn Batch::project(self : Batch, names : Array[String], limits? : Limits = Limits::default()) -> Batch raise OrcError {
  let schema = Schema::new(names.map(name => self.schema.columns[self.schema.index(name)]), limits~)
  Batch::new(schema, names.map(name => self.column(name)), limits~)
}
///| Concatenation requires identical column order and types, never implicit coercion.
pub fn concat(batches : Array[Batch], limits? : Limits = Limits::default()) -> Batch raise OrcError {
  if batches.is_empty() { raise Invalid("concat requires at least one batch", 0) }
  let schema = batches[0].schema
  let columns : Array[Array[Cell]] = Array::makei(schema.columns.length(), _ => [])
  let mut rows = 0
  for batch in batches {
    if batch.schema.columns != schema.columns { raise Invalid("concat schema differs", 0) }
    rows = add(rows, batch.rows)
    if rows > limits.max_rows { raise Limit("concat rows") }
    for i = 0; i < columns.length(); i = i + 1 { columns[i].append(batch.values[i]) }
  }
  Batch::new(schema, columns, limits~)
}
///| Reorder or extend columns by name; missing fields become null, mismatched
///| field types fail rather than silently narrowing integers or shifting dates.
pub fn Batch::align(self : Batch, target : Schema, limits? : Limits = Limits::default()) -> Batch raise OrcError {
  let columns : Array[Array[Cell]] = []
  let by_name : Map[String, Int] = Map([])
  for i = 0; i < self.schema.columns.length(); i = i + 1 { by_name[self.schema.columns[i].name] = i }
  for column in target.columns {
    match by_name.get(column.name) {
      Some(i) => {
        if self.schema.columns[i].kind != column.kind { raise Invalid("align type mismatch: " + column.name, i) }
        columns.push(self.values[i])
      }
      None => columns.push(Array::make(self.rows, Null))
    }
  }
  Batch::new(target, columns, limits~)
}
///| Never allows duplicate output names; original fields remain immutable.
pub fn Batch::rename(self : Batch, mapping : Map[String, String], limits? : Limits = Limits::default()) -> Batch raise OrcError {
  for name, _ in mapping { ignore(self.schema.index(name)) }
  let target = Schema::new(self.schema.columns.map(c => { ..c, name: mapping.get(c.name).unwrap_or(c.name) }), limits~)
  Batch::new(target, self.values, limits~)
}
///|
pub fn Batch::take(self : Batch, rows : Array[Int], limits? : Limits = Limits::default()) -> Batch raise OrcError {
  for row in rows { if row < 0 || row >= self.rows { raise Invalid("take row index", row) } }
  Batch::new(self.schema, self.values.map(c => rows.map(r => c[r])), limits~)
}
///|
test "batch alignment is name-based and preserves nullable missing fields" {
  let schema = Schema::new([{ name: "id", kind: Long }, { name: "s", kind: String }])
  let source = Batch::new(schema, [[Integer(3L), Integer(9L)], [Text("a"), Null]])
  let target = Schema::new([{ name: "s", kind: String }, { name: "added", kind: Boolean }, { name: "id", kind: Long }])
  let aligned = source.align(target)
  assert_eq(aligned.cell(1, "added"), Null)
  assert_eq(aligned.cell(1, "id"), Integer(9L))
  assert_eq(source.take([1, 0, 1]).column("id"), [Integer(9L), Integer(3L), Integer(9L)])
  let joined = concat([source.slice(0, 1), source.slice(1, 1)])
  assert_eq(joined.column("s"), source.column("s"))
  assert_true(try { ignore(source.rename(Map([("s", "id")]))); false } catch { _ => true })
}
