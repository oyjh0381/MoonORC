///|
pub(all) struct ScanMetrics {
  stripes_read : Int32
  stripes_skipped : Int32
  rows_examined : Int32
  rows_returned : Int32
} derive(Debug, Eq)

///|
pub extend ScanMetrics with @debug.Debug::{to_repr}

///|
pub extend ScanMetrics with Eq::{equal, not_equal}

///|
pub struct Scanner {
  priv file : OrcFile
  priv names : Array[String]
  priv required : Array[String]
  priv predicate : Predicate
  priv trust_statistics : Bool
  priv batch_rows : Int32
  priv range_start : Int32
  priv range_end : Int32
  priv mut source_position : Int32
  priv mut stripe_index : Int32
  priv mut pending : Batch?
  priv mut pending_positions : Array[Int32]
  priv mut pending_row : Int32
  priv mut metrics : ScanMetrics
  priv mut failure : OrcError?
}

///|
/// Statistics are untrusted by default. Opt in only for trusted file producers.
pub fn OrcFile::scan(
  self : OrcFile,
  columns~ : Array[String]? = None,
  predicate~ : Predicate = Always(true),
  batch_rows~ : Int32 = 4096,
  trust_statistics~ : Bool = false,
  row_start~ : Int32 = 0,
  row_count~ : Int32? = None,
) -> Scanner raise OrcError {
  if row_start < 0 || row_start > self.rows {
    raise Invalid("scan starting row", row_start)
  }
  let count = row_count.unwrap_or(self.rows - row_start)
  if count < 0 || count > self.rows - row_start {
    raise Invalid("scan row range", row_start)
  }
  if batch_rows <= 0 || batch_rows > self.limits.max_rows {
    raise Limit("scan batch rows")
  }
  let names = columns
    .unwrap_or_else(() => self.schema.columns.map(c => c.name))
    .copy()
  ignore(
    Schema::new(
      names.map(n => self.schema.columns[self.schema.index(n)]),
      limits=self.limits,
    ),
  )
  predicate.validate(self.schema, 0, Ref(self.limits.max_fields))
  let required = names.copy()
  for name in predicate.column_names() {
    if !required.contains(name) {
      required.push(name)
    }
  }
  {
    file: self,
    names,
    required,
    predicate,
    batch_rows,
    trust_statistics,
    range_start: row_start,
    range_end: row_start + count,
    source_position: 0,
    stripe_index: 0,
    pending: None,
    pending_positions: [],
    pending_row: 0,
    failure: None,
    metrics: {
      stripes_read: 0,
      stripes_skipped: 0,
      rows_examined: 0,
      rows_returned: 0,
    },
  }
}

///|
pub fn Scanner::metrics(self : Scanner) -> ScanMetrics {
  self.metrics
}

///|
fn Scanner::advance(self : Scanner) -> PositionedBatch? raise OrcError {
  while true {
    if self.pending is Some(batch) && self.pending_row < batch.rows {
      let count = imin(self.batch_rows, batch.rows - self.pending_row)
      let slice = batch.slice(self.pending_row, count)
      let positions = self.pending_positions[self.pending_row:self.pending_row +
      count].to_owned()
      self.pending_row += count
      let schema = Schema::new(
        self.names.map(n => slice.schema.columns[slice.schema.index(n)]),
        limits=self.file.limits,
      )
      let result = Batch::new(
        schema,
        self.names.map(n => slice.column(n)),
        limits=self.file.limits,
      )
      self.metrics = {
        ..self.metrics,
        rows_returned: add(self.metrics.rows_returned, count),
      }
      return Some({ batch: result, source_rows: positions, })
    }
    self.pending = None
    if self.stripe_index >= self.file.stripes.length() {
      return None
    }
    let index = self.stripe_index
    self.stripe_index += 1
    let rows = self.file.stripes[index].rows
    let stripe_start = self.source_position
    self.source_position = add(self.source_position, rows)
    if stripe_start >= self.range_end ||
      self.source_position <= self.range_start {
      self.metrics = {
        ..self.metrics,
        stripes_skipped: self.metrics.stripes_skipped + 1,
      }
      continue
    }
    if self.trust_statistics &&
      !self.predicate.may_match(
        self.file.schema,
        self.file.stripe_statistics(index),
        rows,
      ) {
      self.metrics = {
        ..self.metrics,
        stripes_skipped: self.metrics.stripes_skipped + 1,
      }
      continue
    }
    let batch = self.file.read_stripe(index, columns=Some(self.required))
    self.metrics = {
      ..self.metrics,
      stripes_read: self.metrics.stripes_read + 1,
      rows_examined: add(self.metrics.rows_examined, rows),
    }
    let start = if self.range_start > stripe_start {
      self.range_start - stripe_start
    } else {
      0
    }
    let end = imin(rows, self.range_end - stripe_start)
    let selected : Array[Int32] = []
    let positions : Array[Int32] = []
    for row = start; row < end; row = row + 1 {
      if self.predicate.evaluate(batch, row) is Yes {
        selected.push(row)
        positions.push(stripe_start + row)
      }
    }
    self.pending = Some(batch.take(selected, limits=self.file.limits))
    self.pending_positions = positions
    self.pending_row = 0
  } nobreak {
    None
  }
}

///| A decoding failure permanently fails this scanner, preventing a retry from

///|
/// silently advancing past the malformed stripe and returning incomplete data.
pub fn Scanner::next(self : Scanner) -> Batch? raise OrcError {
  self.next_positioned().map(p => p.batch)
}

///|
pub(all) struct PositionedBatch {
  batch : Batch
  source_rows : Array[Int32]
}

///|
/// Zero-based source-file row identities survive projection, filtering and batching.
pub fn Scanner::next_positioned(
  self : Scanner,
) -> PositionedBatch? raise OrcError {
  if self.failure is Some(error) {
    raise error
  }
  errdefer {
    self.pending = None
  }
  self.advance() catch {
    Invalid(message, at) => {
      let error : OrcError = Invalid(message, at)
      self.failure = Some(error)
      raise error
    }
    Unsupported(message) => {
      let error : OrcError = Unsupported(message)
      self.failure = Some(error)
      raise error
    }
    Limit(message) => {
      let error : OrcError = Limit(message)
      self.failure = Some(error)
      raise error
    }
  }
}

///|
test "selective scanning filters rows batches output and prunes only on opt-in" {
  let schema = Schema::new([{ name: "x", kind: Long, }])
  let batch = Batch::new(schema, [Array::makei(20, i => Integer(i.to_int64()))])
  let file = OrcFile::open(
    write(batch, options={ ..WriteOptions::default(), stripe_rows: 5, }),
  )
  let scan = file.scan(
    predicate=Compare("x", GreaterEqual, Integer(17L)),
    batch_rows=2,
    trust_statistics=true,
  )
  assert_eq(scan.next().unwrap().column("x"), [Integer(17L), Integer(18L)])
  assert_eq(scan.next().unwrap().column("x"), [Integer(19L)])
  assert_true(scan.next() is None)
  assert_eq(scan.metrics().stripes_skipped, 3)
  let untrusted = file.scan(predicate=Compare("x", GreaterEqual, Integer(17L)))
  while untrusted.next() is Some(_) {
    ()
  }
  assert_eq(untrusted.metrics().stripes_read, 4)
}
