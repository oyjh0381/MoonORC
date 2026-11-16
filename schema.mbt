///|
#derive(Debug, Eq)
pub(all) enum Kind {
  Boolean
  Byte
  Short
  Int
  Long
  Float
  Double
  String
  Binary
  Date
  Timestamp
  TimestampInstant
  Decimal(Int32, Int32)
  Varchar(Int32)
  Char(Int32)
}

///|
pub extend Kind with @debug.Debug::{to_repr}

///|
pub extend Kind with Eq::{equal, not_equal}

///|
#derive(Debug, Eq)
pub(all) struct Column {
  name : String
  kind : Kind
}

///|
pub extend Column with @debug.Debug::{to_repr}

///|
pub extend Column with Eq::{equal, not_equal}

///|
pub struct Schema {
  priv columns : Array[Column]
  priv indexes : Map[String, Int32]
}

///|
pub fn Schema::new(
  columns : Array[Column],
  limits~ : Limits = Limits::default(),
) -> Schema raise OrcError {
  limits.validate()
  if columns.is_empty() || columns.length() > limits.max_columns {
    raise Limit("column count")
  }
  let names : Map[String, Int32] = Map([])
  let mut name_bytes = 0
  for col in columns {
    match col.kind {
      Decimal(p, s) => decimal_kind(p, s)
      Char(n) | Varchar(n) =>
        if n < 1 || n > 65535 {
          raise Invalid("character length must be 1..65535", 0)
        }
      _ => ()
    }
    name_bytes = add(name_bytes, @utf8.encode(col.name).length())
    if name_bytes > limits.max_decoded_bytes {
      raise Limit("schema name bytes")
    }
    if col.name == "" || col.name.contains("\u0000") || names.contains(col.name) {
      raise Invalid("empty/duplicate column name", 0)
    }
    names[col.name] = names.length()
  }
  { columns: columns.copy(), indexes: names, }
}

///|
pub fn Schema::columns(self : Schema) -> Array[Column] {
  self.columns.copy()
}

///|
pub fn Schema::index(self : Schema, name : String) -> Int32 raise OrcError {
  match self.indexes.get(name) {
    Some(index) => index
    None => raise Invalid("unknown column: " + name, 0)
  }
}

///|
fn Kind::code(self : Kind) -> Int32 {
  match self {
    Boolean => 0
    Byte => 1
    Short => 2
    Int => 3
    Long => 4
    Float => 5
    Double => 6
    String => 7
    Binary => 8
    Date => 15
    Timestamp => 9
    TimestampInstant => 18
    Decimal(_, _) => 14
    Varchar(_) => 16
    Char(_) => 17
  }
}

///|
fn kind_from(code : Int32) -> Kind raise OrcError {
  match code {
    0 => Boolean
    1 => Byte
    2 => Short
    3 => Int
    4 => Long
    5 => Float
    6 => Double
    7 => String
    8 => Binary
    15 => Date
    9 => Timestamp
    18 => TimestampInstant
    _ => raise Unsupported("nested or unknown column type")
  }
}

///|
fn Schema::types(self : Schema) -> Array[Bytes] {
  let root = output()
  root.field(1, 12UL)
  let ids = output()
  for i = 0; i < self.columns.length(); i = i + 1 {
    ids.varint((i + 1).to_uint64())
  }
  root.message(2, ids.finish())
  for column in self.columns {
    root.message(3, @utf8.encode(column.name))
  }
  let types = [root.finish()]
  for column in self.columns {
    let t = output()
    t.field(1, column.kind.code().to_uint64())
    match column.kind {
      Decimal(p, s) => {
        t.field(5, p.to_uint64())
        t.field(6, s.to_uint64())
      }
      Char(n) | Varchar(n) => t.field(4, n.to_uint64())
      _ => ()
    }
    types.push(t.finish())
  }
  types
}

///|
fn decode_schema(raws : Array[Bytes], limits : Limits) -> Schema raise OrcError {
  if raws.is_empty() || raws.length() > limits.max_columns + 1 {
    raise Limit("ORC type count")
  }
  let root = parse_proto(raws[0], limits)
  if number(root, 1, 255UL) != 12UL {
    raise Unsupported("ORC root must be flat struct")
  }
  let ids = integers(root, 2)
  let names = blobs(root, 3)
  if ids.length() != names.length() || ids.length() + 1 != raws.length() {
    raise Unsupported("non-flat ORC schema")
  }
  let cols : Array[Column] = []
  for i = 0; i < ids.length(); i = i + 1 {
    if ids[i] != i + 1 {
      raise Unsupported("non-flat type IDs")
    }
    let t = parse_proto(raws[ids[i]], limits)
    if !integers(t, 2).is_empty() {
      raise Unsupported("primitive has subtypes")
    }
    cols.push({
      name: decode_text(names[i]),
      kind: match host(number(t, 1, 255UL)) {
        14 => Decimal(host(number(t, 5, 38UL)), host(number(t, 6, 6UL)))
        16 => Varchar(host(number(t, 4, 0UL)))
        17 => Char(host(number(t, 4, 0UL)))
        n => kind_from(n)
      },
    })
  }
  Schema::new(cols, limits~)
}

///|
test "schema IDs encode a flat typed struct and names are unique" {
  let s = Schema::new([
    { name: "id", kind: Long, },
    { name: "label", kind: String, },
  ])
  assert_eq(decode_schema(s.types(), Limits::default()).columns(), s.columns())
  assert_true(
    try {
      ignore(
        Schema::new([{ name: "x", kind: Long, }, { name: "x", kind: String, }]),
      )
      false
    } catch {
      _ => true
    },
  )
}
