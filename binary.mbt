///|
priv struct Input { bytes : Bytes; mut pos : Int; end : Int }
///|
fn input(bytes : Bytes) -> Input { { bytes, pos: 0, end: bytes.length() } }
///|
fn Input::take(self : Input, size : Int) -> Bytes raise OrcError {
  if size < 0 || size > self.end - self.pos { raise Invalid("truncated field", self.pos) }
  let value = self.bytes[self.pos:self.pos + size].to_owned()
  self.pos += size
  value
}
///|
fn Input::byte(self : Input) -> Int raise OrcError {
  if self.pos >= self.end { raise Invalid("truncated byte", self.pos) }
  let n = self.bytes[self.pos].to_int()
  self.pos += 1
  n
}
///|
fn Input::little(self : Input, width : Int) -> UInt64 raise OrcError {
  let raw = self.take(width)
  let mut n = 0UL
  for i = 0; i < width; i = i + 1 { n = n | (raw[i].to_uint64() << (8 * i)) }
  n
}
///|
fn Input::varint(self : Input) -> UInt64 raise OrcError {
  let mut n = 0UL
  for i = 0; i < 10; i = i + 1 {
    let byte = self.byte()
    if i == 9 && byte > 1 { raise Invalid("varint overflow", self.pos - 1) }
    n = n | ((byte & 127).to_uint64() << (i * 7))
    if byte < 128 { return n }
  }
  raise Invalid("unterminated varint", self.pos)
}
///|
fn host(n : UInt64) -> Int raise OrcError {
  if n > 2147483647UL { raise Limit("host index range") }
  n.to_int()
}
///|
fn zig(n : Int64) -> UInt64 { (n.reinterpret_as_uint64() << 1) ^ ((n >> 63).reinterpret_as_uint64()) }
///|
fn unzig(n : UInt64) -> Int64 { ((n >> 1) ^ (0UL - (n & 1UL))).reinterpret_as_int64() }

///|
priv struct Output { bytes : Array[Byte] }
///|
fn output() -> Output { { bytes: [] } }
///|
fn Output::byte(self : Output, n : Int) -> Unit { self.bytes.push(n.to_byte()) }
///|
fn Output::raw(self : Output, raw : Bytes) -> Unit { for x in raw { self.bytes.push(x) } }
///|
fn Output::little(self : Output, n : UInt64, width : Int) -> Unit {
  for i = 0; i < width; i = i + 1 { self.bytes.push((n >> (8 * i)).to_byte()) }
}
///|
fn Output::varint(self : Output, n : UInt64) -> Unit {
  let mut n = n
  while n >= 128UL { self.bytes.push(((n & 127UL) | 128UL).to_byte()); n = n >> 7 }
  self.bytes.push(n.to_byte())
}
///|
fn Output::finish(self : Output) -> Bytes { Bytes::from_array(self.bytes) }
///|
fn Output::length(self : Output) -> Int { self.bytes.length() }
///|
fn sub(bytes : Bytes, start : Int, size : Int) -> Bytes raise OrcError {
  if start < 0 || size < 0 || start > bytes.length() || size > bytes.length() - start { raise Invalid("byte range", start) }
  bytes[start:start + size].to_owned()
}
///|
test "uint64 varints preserve extremes and reject malformed input" {
  for n in [0UL, 127UL, 128UL, 0xffffffffffffffffUL] {
    let out = output()
    out.varint(n)
    assert_eq(input(out.finish()).varint(), n)
  }
  for n in [-9223372036854775808L, -1L, 0L, 9223372036854775807L] { assert_eq(unzig(zig(n)), n) }
  assert_true(try { ignore(input(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02").varint()); false } catch { _ => true })
}
