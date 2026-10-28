///|
priv struct LocatedStream {
  column : Int32
  kind : Int32
  offset : Int32
  size : Int32
}

///|
priv struct Encoding {
  kind : Int32
  dictionary_size : Int32
}

///|
priv struct Stripe {
  info : StripeInfo
  streams : Array[LocatedStream]
  encodings : Array[Encoding]
}

///|
fn OrcFile::stripe(self : OrcFile, index : Int32) -> Stripe raise OrcError {
  if index < 0 || index >= self.stripes.length() {
    raise Invalid("stripe index", index)
  }
  let info = self.stripes[index]
  let start = add(info.offset, add(info.index_bytes, info.data_bytes))
  let fields = parse_proto(
    decompress(
      sub(self.bytes, start, info.footer_bytes),
      self.compression,
      self.block_size,
      self.limits,
    ),
    self.limits,
  )
  if !blobs(fields, 4).is_empty() {
    raise Unsupported("encrypted stripe footer")
  }
  let encodings : Array[Encoding] = []
  for raw in blobs(fields, 2) {
    let f = parse_proto(raw, self.limits)
    let kind = host(number(f, 1, 0UL))
    if kind > 3 {
      raise Unsupported("column encoding")
    }
    encodings.push({ kind, dictionary_size: host(number(f, 2, 0UL)), })
  }
  if encodings.length() != self.schema.columns.length() + 1 {
    raise Invalid("column encoding count", start)
  }
  let streams : Array[LocatedStream] = []
  let keys : Map[String, Bool] = Map([])
  let mut offset = info.offset
  let data_start = add(info.offset, info.index_bytes)
  for raw in blobs(fields, 1) {
    let f = parse_proto(raw, self.limits)
    let column = host(number(f, 2, 0UL))
    let kind = host(number(f, 1, 255UL))
    let size = host(number(f, 3, 0UL))
    if column > self.schema.columns.length() || kind > 8 {
      raise Unsupported("stream column/kind")
    }
    let key = "\{column}:\{kind}"
    if keys.contains(key) {
      raise Invalid("duplicate column stream", offset)
    }
    keys[key] = true
    let end = add(offset, size)
    if end > start ||
      (kind >= 6 && end > data_start) ||
      (kind < 6 && offset < data_start) {
      raise Invalid("stream exceeds stripe section", offset)
    }
    streams.push({ column, kind, offset, size, })
    offset = end
  }
  if offset != start {
    raise Invalid("stream lengths do not cover stripe", offset)
  }
  if streams.any(s => s.column == 0 && s.kind < 6) {
    raise Unsupported("nullable root struct")
  }
  { info, streams, encodings, }
}

///|
fn OrcFile::stream(
  self : OrcFile,
  stripe : Stripe,
  column : Int32,
  kind : Int32,
) -> Bytes? raise OrcError {
  for s in stripe.streams {
    if s.column == column && s.kind == kind {
      return Some(
        decompress(
          sub(self.bytes, s.offset, s.size),
          self.compression,
          self.block_size,
          self.limits,
        ),
      )
    }
  }
  None
}

///|
fn OrcFile::required_stream(
  self : OrcFile,
  stripe : Stripe,
  column : Int32,
  kind : Int32,
  count : Int32,
) -> Bytes raise OrcError {
  match self.stream(stripe, column, kind) {
    Some(raw) => raw
    None if count == 0 => b""
    _ => raise Invalid("missing column stream", column)
  }
}
