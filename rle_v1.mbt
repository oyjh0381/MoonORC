///| Byte RLE literals contain at most 128 bytes; repeats contain 3..130.
fn encode_bytes(raw : Bytes) -> Bytes {
  let out = output()
  let mut at = 0
  while at < raw.length() {
    let n = imin(128, raw.length() - at)
    out.byte(256 - n)
    out.raw(raw[at:at + n].to_owned())
    at += n
  }
  out.finish()
}
///|
fn decode_bytes(raw : Bytes, count : Int) -> Bytes raise OrcError {
  let c = input(raw)
  let out = output()
  while out.length() < count {
    let control = c.byte()
    if control < 128 {
      let n = control + 3
      if n > count - out.length() { raise Invalid("byte RLE run exceeds expected count", c.pos) }
      let value = c.byte()
      for i = 0; i < n; i = i + 1 { out.byte(value) }
    } else {
      let n = 256 - control
      if n > count - out.length() { raise Invalid("byte RLE literal exceeds expected count", c.pos) }
      out.raw(c.take(n))
    }
  }
  if c.pos != c.end { raise Invalid("trailing byte RLE data", c.pos) }
  out.finish()
}
///|
fn encode_bits(values : Array[Bool]) -> Bytes {
  let packed = output()
  for at = 0; at < values.length(); at = at + 8 {
    let mut byte = 0
    for j = 0; j < 8 && at + j < values.length(); j = j + 1 {
      if values[at + j] { byte = byte | (1 << (7 - j)) }
    }
    packed.byte(byte)
  }
  encode_bytes(packed.finish())
}
///|
fn decode_bits(raw : Bytes, count : Int) -> Array[Bool] raise OrcError {
  let packed = decode_bytes(raw, count / 8 + (if count % 8 == 0 { 0 } else { 1 }))
  Array::makei(count, i => (packed[i / 8].to_int() & (1 << (7 - i % 8))) != 0)
}
///|
fn signed_add(a : Int64, b : Int64) -> Int64 raise OrcError {
  let value = a + b
  if (b > 0 && value < a) || (b < 0 && value > a) { raise Invalid("integer delta overflow", 0) }
  value
}
///|
fn encode_rle1(values : Array[UInt64], signed : Bool) -> Bytes {
  let out = output()
  let mut at = 0
  while at < values.length() {
    let n = imin(128, values.length() - at)
    out.byte(256 - n)
    for i = 0; i < n; i = i + 1 {
      let value = values[at + i]
      out.varint(if signed { zig(value.reinterpret_as_int64()) } else { value })
    }
    at += n
  }
  out.finish()
}
///|
fn decode_rle1(raw : Bytes, count : Int, signed : Bool) -> Array[UInt64] raise OrcError {
  let c = input(raw)
  let out : Array[UInt64] = []
  while out.length() < count {
    let control = c.byte()
    let n = if control < 128 { control + 3 } else { 256 - control }
    if n > count - out.length() { raise Invalid("integer RLE run exceeds column count", c.pos) }
    if control >= 128 {
      for i = 0; i < n; i = i + 1 {
        let value = c.varint()
        out.push(if signed { unzig(value).reinterpret_as_uint64() } else { value })
      }
    } else {
      let delta_byte = c.byte()
      let delta = (if delta_byte < 128 { delta_byte } else { delta_byte - 256 }).to_int64()
      let base = c.varint()
      let mut current = if signed { unzig(base).reinterpret_as_uint64() } else { base }
      for i = 0; i < n; i = i + 1 {
        out.push(current)
        if i + 1 < n {
          if signed { current = signed_add(current.reinterpret_as_int64(), delta).reinterpret_as_uint64() }
          else if delta >= 0 {
            let next = current + delta.reinterpret_as_uint64()
            if next < current { raise Invalid("unsigned delta overflow", c.pos) }
            current = next
          } else {
            let magnitude = (0L - delta).reinterpret_as_uint64()
            if current < magnitude { raise Invalid("unsigned delta underflow", c.pos) }
            current -= magnitude
          }
        }
      }
    }
  }
  if c.pos != c.end { raise Invalid("trailing integer RLE data", c.pos) }
  out
}
///|
test "RLEv1 byte integer and bit streams roundtrip boundaries" {
  let bytes = Bytes::from_array(Array::makei(257, i => i.to_byte()))
  assert_eq(decode_bytes(encode_bytes(bytes), 257), bytes)
  let values = [0UL, 0xffffffffffffffffUL, 0x8000000000000000UL]
  assert_eq(decode_rle1(encode_rle1(values, true), 3, true), values)
  assert_eq(decode_rle1(b"\x00\xff\x0a", 3, false), [10UL, 9UL, 8UL])
  let bits = Array::makei(101, i => i % 3 == 0)
  assert_eq(decode_bits(encode_bits(bits), bits.length()), bits)
}
