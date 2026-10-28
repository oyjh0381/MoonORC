///|
pub(all) struct StripeInfo {
  offset : Int
  index_bytes : Int
  data_bytes : Int
  footer_bytes : Int
  rows : Int
} derive(Debug, Eq)
///|
pub extend StripeInfo with @debug.Debug::{to_repr}
///|
pub extend StripeInfo with Eq::{equal, not_equal}
///|
pub struct OrcFile {
  bytes : Bytes
  schema : Schema
  stripes : Array[StripeInfo]
  compression : Compression
  block_size : Int
  rows : Int
  footer : Array[Field]
  metadata : Array[Field]
  limits : Limits
}
///|
pub fn OrcFile::open(bytes : Bytes, limits? : Limits = Limits::default()) -> OrcFile raise OrcError {
  limits.validate()
  if bytes.length() > limits.max_file_bytes { raise Limit("file bytes") }
  if bytes.length() < 4 || bytes[:3].to_owned() != b"ORC" { raise Invalid("ORC signature", 0) }
  let pslen = bytes[bytes.length() - 1].to_int()
  if pslen == 0 || pslen > bytes.length() - 4 { raise Invalid("postscript size", bytes.length() - 1) }
  let ps_start = bytes.length() - 1 - pslen
  let ps = parse_proto(sub(bytes, ps_start, pslen), limits)
  let magic = blob(ps, 8000, b"ORC")
  if magic != b"ORC" { raise Invalid("postscript magic", ps_start) }
  let version = integers(ps, 4)
  if version != [0, 11] && version != [0, 12] { raise Unsupported("ORC file version") }
  if number(ps, 7, 0UL) != 0UL { raise Unsupported("encrypted stripe statistics") }
  let compression = match number(ps, 2, 0UL) { 0UL => None; 1UL => Zlib; _ => raise Unsupported("compression codec other than NONE/ZLIB") }
  let block_size = host(number(ps, 3, 262144UL))
  let footer_len = host(number(ps, 1, 0UL))
  let meta_len = host(number(ps, 5, 0UL))
  if footer_len > ps_start - 3 || meta_len > ps_start - 3 - footer_len { raise Invalid("tail section bounds", ps_start) }
  let footer_start = ps_start - footer_len
  let metadata_start = footer_start - meta_len
  let footer = parse_proto(decompress(sub(bytes, footer_start, footer_len), compression, block_size, limits), limits)
  if one(footer, 10) is Some(_) { raise Unsupported("encrypted ORC file") }
  if number(footer, 1, 3UL) != 3UL { raise Invalid("header length", footer_start) }
  let schema = decode_schema(blobs(footer, 4), limits)
  let rows = host(number(footer, 6, 0UL))
  if rows > limits.max_rows { raise Limit("file rows") }
  let raw_stripes = blobs(footer, 3)
  if raw_stripes.length() > limits.max_stripes { raise Limit("stripe count") }
  let stripes : Array[StripeInfo] = []
  let mut last_end = 3
  let mut total_rows = 0
  for raw in raw_stripes {
    let s = parse_proto(raw, limits)
    if one(s, 6) is Some(_) || !blobs(s, 7).is_empty() { raise Unsupported("encrypted stripe") }
    let stripe : StripeInfo = { offset: host(number(s, 1, 0UL)), index_bytes: host(number(s, 2, 0UL)), data_bytes: host(number(s, 3, 0UL)), footer_bytes: host(number(s, 4, 0UL)), rows: host(number(s, 5, 0UL)) }
    let end = add(stripe.offset, add(stripe.index_bytes, add(stripe.data_bytes, stripe.footer_bytes)))
    if stripe.offset < last_end || end > metadata_start || stripe.footer_bytes == 0 { raise Invalid("overlapping/out-of-file stripe", stripe.offset) }
    last_end = end
    total_rows = add(total_rows, stripe.rows)
    stripes.push(stripe)
  }
  if total_rows != rows { raise Invalid("stripe/file row total differs", footer_start) }
  let metadata = parse_proto(decompress(sub(bytes, metadata_start, meta_len), compression, block_size, limits), limits)
  { bytes, schema, stripes, compression, block_size, rows, footer, metadata, limits }
}
///|
pub fn OrcFile::schema(self : OrcFile) -> Schema { self.schema }
///|
pub fn OrcFile::row_count(self : OrcFile) -> Int { self.rows }
///|
pub fn OrcFile::stripes(self : OrcFile) -> Array[StripeInfo] { self.stripes.copy() }
///|
pub fn OrcFile::compression(self : OrcFile) -> Compression { self.compression }
///|
pub fn OrcFile::user_metadata(self : OrcFile) -> Map[String, Bytes] raise OrcError {
  let out : Map[String, Bytes] = Map([])
  for raw in blobs(self.footer, 5) {
    let fields = parse_proto(raw, self.limits)
    let name = decode_text(blob(fields, 1, b""))
    if out.contains(name) { raise Invalid("duplicate user metadata", 0) }
    out[name] = blob(fields, 2, b"")
  }
  out
}
