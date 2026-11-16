///| Incremental input writer retains encoded stripes, not all source batches.

///|
/// It is not a disk streaming writer; finish returns one bounded byte buffer.
pub struct Writer {
  priv schema : Schema
  priv options : WriteOptions
  priv limits : Limits
  priv body : Array[Byte]
  priv statistics : Array[Byte]
  priv stripes : Array[StripeInfo]
  priv mut rows : Int32
  priv mut closed : Bool
}

///|
pub fn Writer::new(
  schema : Schema,
  options~ : WriteOptions = WriteOptions::default(),
  limits~ : Limits = Limits::default(),
) -> Writer raise OrcError {
  limits.validate()
  options.validate(limits)
  ignore(Schema::new(schema.columns, limits~))
  {
    schema,
    options,
    limits,
    body: [b'O', b'R', b'C'],
    statistics: [],
    stripes: [],
    rows: 0,
    closed: false,
  }
}

///|
/// Stage a whole push before mutation; bad batches never corrupt prior output.
pub fn Writer::push(self : Writer, batch : Batch) -> Unit raise OrcError {
  if self.closed {
    raise Invalid("writer already finished", 0)
  }
  if batch.schema.columns != self.schema.columns {
    raise Invalid("writer batch schema differs", 0)
  }
  let rows = add(self.rows, batch.rows)
  if rows > self.limits.max_rows {
    raise Limit("writer total rows")
  }
  ignore(Batch::new(batch.schema, batch.values, limits=self.limits))
  let stage = output()
  let stats = output()
  let stage_limits = {
    ..self.limits,
    max_file_bytes: self.limits.max_file_bytes - self.body.length(),
  }
  let stripes : Array[StripeInfo] = []
  let mut at = 0
  while at < batch.rows {
    if self.stripes.length() + stripes.length() >= self.limits.max_stripes {
      raise Limit("writer stripes")
    }
    let count = imin(self.options.stripe_rows, batch.rows - at)
    let part = batch.slice(at, count)
    let s = write_stripe(part, stage, self.options, stage_limits)
    stripes.push({ ..s, offset: add(s.offset, self.body.length()), })
    let stripe_stat = output()
    let root = output()
    root.field(1, count.to_uint64())
    root.field(10, 0UL)
    stripe_stat.message(1, root.finish())
    for i = 0; i < self.schema.columns.length(); i = i + 1 {
      stripe_stat.message(
        1,
        encode_statistics(part.values[i], self.schema.columns[i].kind),
      )
    }
    stats.message(1, stripe_stat.finish())
    if add(self.statistics.length(), stats.length()) >
      self.limits.max_decoded_bytes {
      raise Limit("staged writer bytes")
    }
    at += count
  }
  self.body.append(stage.bytes)
  self.statistics.append(stats.bytes)
  self.stripes.append(stripes)
  self.rows = rows
}

///|
/// Failure leaves the writer open; success closes it and releases retained bytes.
pub fn Writer::finish(
  self : Writer,
  metadata~ : Map[String, Bytes] = Map([]),
) -> Bytes raise OrcError {
  if self.closed {
    raise Invalid("writer already finished", 0)
  }
  let body : Output = { bytes: self.body.copy(), }
  let result = finish_file(
    body,
    self.schema,
    self.stripes,
    Bytes::from_array(self.statistics),
    self.rows,
    self.options,
    metadata,
    self.limits,
  )
  self.closed = true
  self.body.clear()
  self.statistics.clear()
  self.stripes.clear()
  result
}

///|
pub fn Writer::row_count(self : Writer) -> Int32 {
  self.rows
}

///|
test "incremental input writer stages batches and preserves previous rows on failure" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let writer = Writer::new(schema, options={
    ..WriteOptions::default(),
    stripe_rows: 2,
  })
  writer.push(Batch::new(schema, [[Integer(1L), Integer(2L), Null]]))
  let other = Schema::new([{ name: "x", kind: String, }])
  assert_true(
    try {
      writer.push(Batch::new(other, [[Text("bad")]]))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(writer.row_count(), 3)
  writer.push(Batch::new(schema, [[Integer(4L)]]))
  let file = OrcFile::open(writer.finish())
  assert_eq(file.row_count(), 4)
  assert_eq(file.stripes().length(), 3)
  assert_eq(file.read_stripe(2).cell(0, "x"), Integer(4L))
  assert_true(
    try {
      ignore(writer.finish())
      false
    } catch {
      _ => true
    },
  )
}
