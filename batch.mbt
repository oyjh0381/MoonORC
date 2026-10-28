///|
pub(all) enum Cell {
  Null
  Bool(Bool)
  Integer(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
  Days(Int32)
} derive(Debug, Eq)

///|
pub extend Cell with @debug.Debug::{to_repr}

///|
pub extend Cell with Eq::{equal, not_equal}

///|
pub struct Batch {
  schema : Schema
  values : Array[Array[Cell]]
  rows : Int32
}

///|
fn Cell::validate(self : Cell, kind : Kind) -> Unit raise OrcError {
  let valid = match (self, kind) {
    (Null, _) => true
    (Bool(_), Boolean) => true
    (Integer(n), Byte) => n >= -128L && n <= 127L
    (Integer(n), Short) => n >= -32768L && n <= 32767L
    (Integer(n), Int) => n >= -2147483648L && n <= 2147483647L
    (Integer(_), Long) => true
    (Real(_), Double) => true
    (Real(n), Float) =>
      n.is_nan() ||
      n.is_inf() ||
      (n >= -3.4028234663852886e38 && n <= 3.4028234663852886e38)
    (Text(_), String) => true
    (Blob(_), Binary) => true
    (Days(_), Date) => true
    _ => false
  }
  if !valid {
    raise Invalid("cell does not match column type/range", 0)
  }
}

///|
pub fn Batch::new(
  schema : Schema,
  columns : Array[Array[Cell]],
  limits~ : Limits = Limits::default(),
) -> Batch raise OrcError {
  limits.validate()
  if columns.length() != schema.columns.length() {
    raise Invalid("batch column count", 0)
  }
  let rows = columns[0].length()
  if rows > limits.max_rows {
    raise Limit("batch rows")
  }
  let mut bytes = mul(mul(rows, columns.length()), 8)
  for i = 0; i < columns.length(); i = i + 1 {
    if columns[i].length() != rows {
      raise Invalid("ragged batch", i)
    }
    for value in columns[i] {
      value.validate(schema.columns[i].kind)
      match value {
        Text(s) => bytes = add(bytes, @utf8.encode(s).length())
        Blob(b) => bytes = add(bytes, b.length())
        _ => ()
      }
      if bytes > limits.max_decoded_bytes {
        raise Limit("batch retained bytes")
      }
    }
  }
  { schema, values: columns.map(a => a.copy()), rows, }
}

///|
pub fn Batch::schema(self : Batch) -> Schema {
  self.schema
}

///|
pub fn Batch::row_count(self : Batch) -> Int32 {
  self.rows
}

///|
pub fn Batch::column(self : Batch, name : String) -> Array[Cell] raise OrcError {
  self.values[self.schema.index(name)].copy()
}

///|
pub fn Batch::cell(
  self : Batch,
  row : Int32,
  column : String,
) -> Cell raise OrcError {
  if row < 0 || row >= self.rows {
    raise Invalid("row index", row)
  }
  self.values[self.schema.index(column)][row]
}

///|
pub fn Batch::slice(
  self : Batch,
  start : Int32,
  count : Int32,
) -> Batch raise OrcError {
  if start < 0 || count < 0 || start > self.rows || count > self.rows - start {
    raise Invalid("batch slice", start)
  }
  {
    schema: self.schema,
    rows: count,
    values: self.values.map(c => c[start:start + count].to_owned()),
  }
}

///|
test "nullable batch is immutable and rejects ragged or mistyped columns" {
  let schema = Schema::new([
    { name: "x", kind: Long, },
    { name: "s", kind: String, },
  ])
  let source : Array[Cell] = [Integer(1L), Null]
  let batch = Batch::new(schema, [source, [Text(""), Text("你好")]])
  source[0] = Integer(9L)
  assert_eq(batch.cell(0, "x"), Integer(1L))
  assert_eq(batch.slice(1, 1).cell(0, "x"), Null)
  assert_true(
    try {
      ignore(Batch::new(schema, [[Null], []]))
      false
    } catch {
      _ => true
    },
  )
}
