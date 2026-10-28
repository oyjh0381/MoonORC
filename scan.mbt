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
  file : OrcFile
  names : Array[String]
  required : Array[String]
  predicate : Predicate
  trust_statistics : Bool
  batch_rows : Int32
  mut stripe_index : Int32
  mut pending : Batch?
  mut pending_row : Int32
  mut metrics : ScanMetrics
}

///|
/// Statistics are untrusted by default. Opt in only for trusted file producers.
pub fn OrcFile::scan(
  self : OrcFile,
  columns~ : Array[String]? = None,
  predicate~ : Predicate = Always(true),
  batch_rows~ : Int32 = 4096,
  trust_statistics~ : Bool = false,
) -> Scanner raise OrcError {
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
  predicate.validate(self.schema, 0)
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
    stripe_index: 0,
    pending: None,
    pending_row: 0,
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
pub fn Scanner::next(self : Scanner) -> Batch? raise OrcError {
  while true {
    if self.pending is Some(batch) && self.pending_row < batch.rows {
      let count = imin(self.batch_rows, batch.rows - self.pending_row)
      let slice = batch.slice(self.pending_row, count)
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
      return Some(result)
    }
    self.pending = None
    if self.stripe_index >= self.file.stripes.length() {
      return None
    }
    let index = self.stripe_index
    self.stripe_index += 1
    let rows = self.file.stripes[index].rows
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
    self.pending = Some(batch.filter(self.predicate, limits=self.file.limits))
    self.pending_row = 0
  } nobreak {
    None
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
