///|
pub(all) struct WriteOptions {
  compression : Compression
  block_size : Int32
  stripe_rows : Int32
} derive(Debug, Eq)

///|
pub extend WriteOptions with @debug.Debug::{to_repr}

///|
pub extend WriteOptions with Eq::{equal, not_equal}

///|
pub fn WriteOptions::default() -> WriteOptions {
  { compression: None, block_size: 262144, stripe_rows: 10000, }
}

///|
fn WriteOptions::validate(
  self : WriteOptions,
  limits : Limits,
) -> Unit raise OrcError {
  if self.stripe_rows <= 0 ||
    self.stripe_rows > limits.max_rows ||
    self.block_size <= 0 ||
    self.block_size > 8388607 ||
    self.block_size > limits.max_decoded_bytes {
    raise Limit("writer stripe/block configuration")
  }
}

///|
fn stripe_message(info : StripeInfo) -> Bytes {
  let b = output()
  b.field(1, info.offset.to_uint64())
  b.field(2, info.index_bytes.to_uint64())
  b.field(3, info.data_bytes.to_uint64())
  b.field(4, info.footer_bytes.to_uint64())
  b.field(5, info.rows.to_uint64())
  b.finish()
}

///|
fn write_stripe(
  batch : Batch,
  body : Output,
  options : WriteOptions,
  limits : Limits,
) -> StripeInfo raise OrcError {
  let start = body.length()
  let footer = output()
  let root = output()
  root.field(1, 0UL)
  let encodings = [root.finish()]
  for index = 0; index < batch.schema.columns.length(); index = index + 1 {
    let column = encode_column(
      batch.schema.columns[index].kind,
      batch.values[index],
    )
    let enc = output()
    enc.field(1, column.encoding.to_uint64())
    enc.field(2, column.dictionary_size.to_uint64())
    encodings.push(enc.finish())
    for (kind, bytes) in column.streams {
      let encoded = compress(bytes, options.compression, options.block_size)
      if add(body.length(), encoded.length()) > limits.max_file_bytes {
        raise Limit("ORC output bytes")
      }
      let stream = output()
      stream.field(1, kind.to_uint64())
      stream.field(2, (index + 1).to_uint64())
      stream.field(3, encoded.length().to_uint64())
      footer.message(1, stream.finish())
      body.raw(encoded)
    }
  }
  for enc in encodings {
    footer.message(2, enc)
  }
  let data_bytes = body.length() - start
  let encoded_footer = compress(
    footer.finish(),
    options.compression,
    options.block_size,
  )
  body.raw(encoded_footer)
  {
    offset: start,
    index_bytes: 0,
    data_bytes,
    footer_bytes: encoded_footer.length(),
    rows: batch.rows,
  }
}

///|
pub fn write(
  batch : Batch,
  options~ : WriteOptions = WriteOptions::default(),
  metadata~ : Map[String, Bytes] = Map([]),
  limits~ : Limits = Limits::default(),
) -> Bytes raise OrcError {
  limits.validate()
  options.validate(limits)
  ignore(Batch::new(batch.schema, batch.values, limits~))
  let body = output()
  body.raw(b"ORC")
  let stripes : Array[StripeInfo] = []
  let metadata_section = output()
  let mut at = 0
  while at < batch.rows {
    if stripes.length() >= limits.max_stripes {
      raise Limit("writer stripe count")
    }
    let count = imin(options.stripe_rows, batch.rows - at)
    let stripe_batch = batch.slice(at, count)
    stripes.push(write_stripe(stripe_batch, body, options, limits))
    let stripe_stats = output()
    let root_stats = output()
    root_stats.field(1, count.to_uint64())
    root_stats.field(10, 0UL)
    stripe_stats.message(1, root_stats.finish())
    for i = 0; i < batch.schema.columns.length(); i = i + 1 {
      stripe_stats.message(
        1,
        encode_statistics(stripe_batch.values[i], batch.schema.columns[i].kind),
      )
    }
    metadata_section.message(1, stripe_stats.finish())
    at += count
  }
  finish_file(body, batch.schema, stripes, metadata_section.finish(), batch.rows, options, metadata, limits)
}

///|
fn finish_file(body : Output, schema : Schema, stripes : Array[StripeInfo], stripe_statistics : Bytes, rows : Int, options : WriteOptions, metadata : Map[String, Bytes], limits : Limits) -> Bytes raise OrcError {
  let content_length = body.length()
  let encoded_metadata = compress(
    stripe_statistics,
    options.compression,
    options.block_size,
  )
  body.raw(encoded_metadata)
  let footer = output()
  footer.field(1, 3UL)
  footer.field(2, content_length.to_uint64())
  for stripe in stripes {
    footer.message(3, stripe_message(stripe))
  }
  for t in schema.types() {
    footer.message(4, t)
  }
  let names = metadata.keys().collect()
  names.sort()
  for name in names {
    let m = output()
    m.message(1, @utf8.encode(name))
    m.message(2, metadata.get(name).unwrap())
    footer.message(5, m.finish())
  }
  footer.field(6, rows.to_uint64())
  footer.field(8, 0UL)
  footer.field(11, 2UL)
  footer.message(12, b"MoonORC 0.1.0")
  let raw_footer = compress(
    footer.finish(),
    options.compression,
    options.block_size,
  )
  body.raw(raw_footer)
  let ps = output()
  ps.field(1, raw_footer.length().to_uint64())
  ps.field(2, if options.compression == None { 0UL } else { 1UL })
  ps.field(3, options.block_size.to_uint64())
  ps.message(4, b"\x00\x0c")
  ps.field(5, encoded_metadata.length().to_uint64())
  ps.field(6, 6UL)
  ps.message(8000, b"ORC")
  if ps.length() > 255 {
    raise Limit("postscript length")
  }
  body.raw(ps.finish())
  body.byte(ps.length())
  if body.length() > limits.max_file_bytes {
    raise Limit("output file size")
  }
  body.finish()
}

///|
test "real ORC stripes roundtrip nullable records with projection" {
  let schema = Schema::new([
    { name: "id", kind: Long, },
    { name: "label", kind: String, },
    { name: "ok", kind: Boolean, },
  ])
  let batch = Batch::new(schema, [
    [Integer(1L), Null, Integer(-3L)],
    [Text("你好"), Text(""), Null],
    [Bool(true), Null, Bool(false)],
  ])
  for compression in [None, Zlib] {
    let file = OrcFile::open(
      write(batch, options={
        ..WriteOptions::default(),
        compression,
        stripe_rows: 2,
      }),
    )
    assert_eq(file.stripes().length(), 2)
    assert_eq(
      file.read_stripe(0, columns=Some(["label"])).cell(0, "label"),
      Text("你好"),
    )
    assert_eq(file.read_stripe(1).cell(0, "id"), Integer(-3L))
  }
}
