///|
pub(all) struct SortKey {
  column : String
  descending : Bool
  nulls_first : Bool
}

///|
fn order_value(a : Cell, b : Cell, key : SortKey) -> Int32 {
  if a is Null {
    return if b is Null { 0 } else if key.nulls_first { -1 } else { 1 }
  }
  if b is Null {
    return if key.nulls_first { 1 } else { -1 }
  }
  let order = match (a, b) {
    (Real(x), Real(y)) if x.is_nan() || y.is_nan() =>
      if x.is_nan() && y.is_nan() {
        0
      } else if x.is_nan() {
        1
      } else {
        -1
      }
    _ => compare_cell(a, b).unwrap_or(0)
  }
  if key.descending {
    -order
  } else {
    order
  }
}

///|
/// Stable typed multi-key ordering. Null placement is independent of direction.
/// NaNs tie and follow numeric values ascending. Binary keys are rejected.
pub fn Batch::sort_rows(
  self : Batch,
  keys : Array[SortKey],
  limits~ : Limits = Limits::default(),
) -> Batch raise OrcError {
  ignore(Batch::new(self.schema, self.values, limits~))
  if self.schema.columns.length() > limits.max_columns {
    raise Limit("sort input columns")
  }
  if keys.is_empty() || keys.length() > limits.max_columns {
    raise Invalid("sort keys", 0)
  }
  let indexes : Array[Int32] = []
  let seen : Map[String, Bool] = Map([])
  for key in keys {
    if seen.contains(key.column) {
      raise Invalid("duplicate sort key", 0)
    }
    seen[key.column] = true
    let i = self.schema.index(key.column)
    if self.schema.columns[i].kind == Binary {
      raise Unsupported("binary sort keys")
    }
    indexes.push(i)
  }
  let rows = Array::makei(self.rows, i => i)
  rows.sort_by((a, b) => {
    for i = 0; i < indexes.length(); i = i + 1 {
      let order = order_value(
        self.values[indexes[i]][a],
        self.values[indexes[i]][b],
        keys[i],
      )
      if order != 0 {
        return order
      }
    }
    a.compare(b)
  })
  self.take(rows, limits~)
}

///|
fn exact_cell_key(cell : Cell, maximum : Int32) -> String raise OrcError {
  match cell {
    Null => "N"
    Bool(v) => if v { "B1" } else { "B0" }
    Integer(v) => "I" + v.to_string()
    Days(v) => "D" + v.to_string()
    Real(v) => "R" + v.reinterpret_as_uint64().to_string()
    Text(v) => "T" + v
    Blob(v) => {
      // Each byte needs at most three decimal digits and a separator. Bound
      // the expansion before allocating a large textual binary identity.
      if v.length() > (maximum - 1) / 4 {
        raise Limit("binary unique key expansion")
      }
      let b = StringBuilder()
      b.write_string("X")
      for byte in v {
        b.write_string(byte.to_int().to_string())
        b.write_string(";")
      }
      b.to_string()
    }
  }
}

///|
/// Keep the first row of each exact typed key. Floating identity uses raw bits,
/// so signed zeros and different NaN payloads remain distinct.
pub fn Batch::unique_rows(
  self : Batch,
  keys : Array[String],
  limits~ : Limits = Limits::default(),
) -> Batch raise OrcError {
  ignore(Batch::new(self.schema, self.values, limits~))
  if self.schema.columns.length() > limits.max_columns {
    raise Limit("unique input columns")
  }
  if keys.is_empty() || keys.length() > limits.max_columns {
    raise Invalid("unique keys", 0)
  }
  let indexes : Array[Int32] = []
  let names : Map[String, Bool] = Map([])
  for name in keys {
    if names.contains(name) {
      raise Invalid("duplicate unique key", 0)
    }
    names[name] = true
    indexes.push(self.schema.index(name))
  }
  let seen : Map[String, Bool] = Map([])
  let rows : Array[Int32] = []
  let mut retained = 0
  for row = 0; row < self.rows; row = row + 1 {
    let b = StringBuilder()
    let mut size = 0
    for index in indexes {
      let value = exact_cell_key(
        self.values[index][row],
        limits.max_decoded_bytes,
      )
      let prefix = value.length().to_string() + ":"
      size = add(size, add(@utf8.encode(value).length(), prefix.length()))
      if size > limits.max_decoded_bytes {
        raise Limit("unique key bytes")
      }
      b.write_string(prefix)
      b.write_string(value)
    }
    let key = b.to_string()
    if !seen.contains(key) {
      retained = add(retained, size)
      if retained > limits.max_decoded_bytes {
        raise Limit("unique retained keys")
      }
      seen[key] = true
      rows.push(row)
    }
  }
  self.take(rows, limits~)
}
