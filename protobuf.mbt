///| Only wire values, not generated classes. Unknown fields remain bounded.
priv enum Wire { Var(UInt64); Data(Bytes); Fixed(UInt64) }
///|
priv struct Field { id : Int; wire : Wire }
///|
fn parse_proto(raw : Bytes, limits : Limits) -> Array[Field] raise OrcError {
  if raw.length() > limits.max_decoded_bytes { raise Limit("protobuf bytes") }
  let c = input(raw)
  let out : Array[Field] = []
  while c.pos < c.end {
    if out.length() >= limits.max_fields { raise Limit("protobuf fields") }
    let tag = host(c.varint())
    if tag >> 3 == 0 { raise Invalid("zero protobuf field", c.pos) }
    let wire = match tag & 7 {
      0 => Var(c.varint())
      1 => Fixed(c.little(8))
      2 => { let n = host(c.varint()); Data(c.take(n)) }
      5 => Fixed(c.little(4))
      _ => raise Unsupported("protobuf wire groups/type")
    }
    out.push({ id: tag >> 3, wire })
  }
  out
}
///|
fn one(fields : Array[Field], id : Int) -> Wire? raise OrcError {
  let mut found : Wire? = None
  for f in fields {
    if f.id == id {
      if found is Some(_) { raise Invalid("duplicate singular protobuf field", id) }
      found = Some(f.wire)
    }
  }
  found
}
///|
fn number(fields : Array[Field], id : Int, fallback : UInt64) -> UInt64 raise OrcError {
  match one(fields, id) { None => fallback; Some(Var(n)) => n; _ => raise Invalid("expected protobuf integer", id) }
}
///|
fn blob(fields : Array[Field], id : Int, fallback : Bytes) -> Bytes raise OrcError {
  match one(fields, id) { None => fallback; Some(Data(n)) => n; _ => raise Invalid("expected protobuf message", id) }
}
///|
fn blobs(fields : Array[Field], id : Int) -> Array[Bytes] raise OrcError {
  let out : Array[Bytes] = []
  for f in fields { if f.id == id { match f.wire { Data(b) => out.push(b); _ => raise Invalid("expected repeated message", id) } } }
  out
}
///|
fn integers(fields : Array[Field], id : Int) -> Array[Int] raise OrcError {
  let out : Array[Int] = []
  for f in fields {
    if f.id == id {
      match f.wire {
        Var(n) => out.push(host(n))
        Data(b) => { let c = input(b); while c.pos < c.end { out.push(host(c.varint())) } }
        _ => raise Invalid("expected packed integers", id)
      }
    }
  }
  out
}
///|
fn Output::field(self : Output, id : Int, n : UInt64) -> Unit { self.varint((id * 8).to_uint64()); self.varint(n) }
///|
fn Output::message(self : Output, id : Int, raw : Bytes) -> Unit {
  self.varint((id * 8 + 2).to_uint64()); self.varint(raw.length().to_uint64()); self.raw(raw)
}
///|
fn decode_text(raw : Bytes) -> String raise OrcError {
  try @utf8.decode(raw, ignore_bom=false) catch { _ => raise Invalid("invalid UTF8", 0) }
}
///|
test "protobuf accepts packed fields and skips unfamiliar typed values" {
  let b = output()
  b.field(1, 5UL)
  b.message(2, b"\x01\x7f")
  let fields = parse_proto(b.finish(), Limits::default())
  assert_eq(number(fields, 1, 0UL), 5UL)
  assert_eq(integers(fields, 2), [1, 127])
  assert_true(try { ignore(parse_proto(b"\x00", Limits::default())); false } catch { _ => true })
}
