///| Missing bounds are not a proof. Counts describe non-null values only.
pub(all) struct Statistics {
  count : Int?
  has_null : Bool?
  minimum : Cell?
  maximum : Cell?
} derive(Debug, Eq)
///|
pub extend Statistics with @debug.Debug::{to_repr}
///|
pub extend Statistics with Eq::{equal, not_equal}
///|
fn utf8_compare(a : String, b : String) -> Int {
  let a = @utf8.encode(a)
  let b = @utf8.encode(b)
  for i = 0; i < imin(a.length(), b.length()); i = i + 1 {
    if a[i] < b[i] { return -1 }
    if a[i] > b[i] { return 1 }
  }
  a.length().compare(b.length())
}
///| None means incomparable (including NaN), never an arbitrary ordering.
fn compare_cell(a : Cell, b : Cell) -> Int? {
  match (a, b) {
    (Integer(a), Integer(b)) => Some(a.compare(b))
    (Days(a), Days(b)) => Some(a.compare(b))
    (Text(a), Text(b)) => Some(utf8_compare(a, b))
    (Bool(a), Bool(b)) => Some((if a { 1 } else { 0 }).compare(if b { 1 } else { 0 }))
    (Real(a), Real(b)) if !a.is_nan() && !b.is_nan() => Some(if a < b { -1 } else if a > b { 1 } else { 0 })
    _ => None
  }
}
///|
fn summarize(values : Array[Cell]) -> Statistics {
  let mut count = 0
  let mut min : Cell? = None
  let mut max : Cell? = None
  let mut no_bounds = false
  for v in values {
    if v == Null { continue }
    count += 1
    if v is Blob(_) { no_bounds = true }
    if v is Real(_) { no_bounds = true } // Do not emit floating bounds with subtle NaN semantics.
    match min {
      None => { min = Some(v); max = Some(v) }
      Some(low) => {
        if compare_cell(v, low) == Some(-1) { min = Some(v) }
        if compare_cell(v, max.unwrap()) == Some(1) { max = Some(v) }
      }
    }
  }
  { count: Some(count), has_null: Some(count != values.length()), minimum: if no_bounds { None } else { min }, maximum: if no_bounds { None } else { max } }
}
///|
fn encode_statistics(values : Array[Cell], kind : Kind) -> Bytes {
  let s = summarize(values)
  let b = output()
  b.field(1, s.count.unwrap().to_uint64())
  b.field(10, if s.has_null == Some(true) { 1UL } else { 0UL })
  if s.minimum is Some(low) && s.maximum is Some(high) {
    let bounds = output()
    match (low, high, kind) {
      (Integer(a), Integer(z), _) => { bounds.field(1, zig(a)); bounds.field(2, zig(z)); b.message(2, bounds.finish()) }
      (Days(a), Days(z), _) => { bounds.field(1, zig(a.to_int64())); bounds.field(2, zig(z.to_int64())); b.message(7, bounds.finish()) }
      (Text(a), Text(z), _) => { bounds.message(1, @utf8.encode(a)); bounds.message(2, @utf8.encode(z)); b.message(4, bounds.finish()) }
      _ => ()
    }
  }
  b.finish()
}
///|
fn decode_statistics(raw : Bytes, kind : Kind, rows : Int, limits : Limits) -> Statistics raise OrcError {
  let fields = parse_proto(raw, limits)
  let count = match one(fields, 1) { Some(Var(n)) => Some(host(n)); None => None; _ => raise Invalid("statistics count wire type", 0) }
  if count is Some(n) && n > rows { raise Invalid("statistics count exceeds stripe rows", 0) }
  let has_null = match one(fields, 10) { Some(Var(n)) if n <= 1UL => Some(n == 1UL); None => None; _ => raise Invalid("statistics null flag", 0) }
  let bounds_id = match kind { Byte | Short | Int | Long => 2; String => 4; Date => 7; _ => 0 }
  let bounds = if bounds_id == 0 { [] } else { parse_proto(blob(fields, bounds_id, b""), limits) }
  let make_bound = fn(id : Int) -> Cell? raise OrcError {
    match one(bounds, id) {
      Some(Var(n)) if bounds_id == 2 => Some(Integer(unzig(n)))
      Some(Var(n)) if bounds_id == 7 => {
        let n = unzig(n)
        if n < -2147483648L || n > 2147483647L { raise Invalid("date statistics range", 0) }
        Some(Days(n.to_int()))
      }
      Some(Data(b)) if bounds_id == 4 => Some(Text(decode_text(b)))
      None => None
      _ => raise Invalid("statistics bounds wire", id)
    }
  }
  let minimum = make_bound(1)
  let maximum = make_bound(2)
  if minimum is Some(a) && maximum is Some(z) && compare_cell(a, z) == Some(1) { raise Invalid("statistics minimum exceeds maximum", 0) }
  { count, has_null, minimum, maximum }
}
///|
pub fn OrcFile::stripe_statistics(self : OrcFile, index : Int) -> Array[Statistics] raise OrcError {
  if index < 0 || index >= self.stripes.length() { raise Invalid("stripe index", index) }
  let raw = blobs(parse_proto(self.metadata, self.limits), 1)
  if raw.is_empty() { return Array::make(self.schema.columns.length(), { count: None, has_null: None, minimum: None, maximum: None }) }
  if raw.length() != self.stripes.length() { raise Invalid("stripe statistics count", 0) }
  let columns = blobs(parse_proto(raw[index], self.limits), 1)
  if columns.length() != self.schema.columns.length() + 1 { raise Invalid("column statistics count", 0) }
  Array::makei(self.schema.columns.length(), i => decode_statistics(columns[i + 1], self.schema.columns[i].kind, self.stripes[index].rows, self.limits))
}
///|
test "statistics compare UTF8 codepoint order rather than UTF16 surrogate order" {
  assert_eq(utf8_compare("\u{10000}", "\ue000"), 1)
  let s = summarize([Integer(-2L), Null, Integer(5L)])
  assert_eq(s.minimum, Some(Integer(-2L)))
  assert_eq(s.count, Some(2))
  assert_eq(s.has_null, Some(true))
}
