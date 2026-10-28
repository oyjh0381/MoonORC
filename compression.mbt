///|
pub(all) enum Compression { None; Zlib } derive(Debug, Eq)
///|
pub extend Compression with @debug.Debug::{to_repr}
///|
pub extend Compression with Eq::{equal, not_equal}

///| ORC ZLIB framing contains raw DEFLATE, not RFC1950 zlib headers.
fn decompress(raw : Bytes, kind : Compression, block_size : Int, limits : Limits) -> Bytes raise OrcError {
  if raw.length() > limits.max_file_bytes { raise Limit("encoded stream bytes") }
  if kind == None {
    if raw.length() > limits.max_decoded_bytes { raise Limit("decoded stream bytes") }
    return raw
  }
  if block_size <= 0 || block_size > limits.max_decoded_bytes { raise Limit("compression block size") }
  let c = input(raw)
  let out = output()
  while c.pos < c.end {
    let header = host(c.little(3))
    let size = header >> 1
    if size <= 0 || size > block_size { raise Invalid("compression chunk size", c.pos) }
    let remaining = limits.max_decoded_bytes - out.length()
    let capacity = imin(block_size, remaining)
    let bytes = c.take(size)
    let decoded = if (header & 1) == 1 { bytes } else {
      try @flate.inflate_exact(bytes, max_output=capacity) catch { _ => raise Invalid("invalid/oversized compressed stream", c.pos) }
    }
    if decoded.length() > capacity { raise Limit("decompressed output") }
    out.raw(decoded)
  }
  out.finish()
}

///|
fn compress(raw : Bytes, kind : Compression, block_size : Int) -> Bytes {
  if kind == None { return raw }
  let out = output()
  let mut at = 0
  while at < raw.length() {
    let n = imin(block_size, raw.length() - at)
    let original = raw[at:at + n].to_owned()
    let zipped = @flate.deflate_all(original)
    let use_original = zipped.length() >= n
    let bytes = if use_original { original } else { zipped }
    out.little((bytes.length() * 2 + (if use_original { 1 } else { 0 })).to_uint64(), 3)
    out.raw(bytes)
    at += n
  }
  out.finish()
}
///|
test "ORC compression blocks are bounded raw deflate with original fallback" {
  let bytes = Bytes::from_array(Array::make(2000, b'a'))
  let zipped = compress(bytes, Zlib, 512)
  assert_eq(decompress(zipped, Zlib, 512, Limits::default()), bytes)
  assert_true(try { ignore(decompress(zipped, Zlib, 512, { ..Limits::default(), max_decoded_bytes: 1000 })); false } catch { _ => true })
}
