///|
/// Export typed service logs; select only identifiers and route for errors.
fn main raise {
  let schema = @orc.Schema::new([
    { name: "request_id", kind: Long, },
    { name: "route", kind: String, },
    { name: "status", kind: Int, },
    { name: "latency_ms", kind: Double, },
  ])
  let writer = @orc.Writer::new(schema, options={
    ..@orc.WriteOptions::default(),
    compression: Zlib,
    stripe_rows: 4,
  })
  for batch_index = 0; batch_index < 4; batch_index = batch_index + 1 {
    let start = batch_index * 4
    writer.push(
      @orc.Batch::new(schema, [
        Array::makei(4, i => Integer((start + i).to_int64())),
        Array::makei(4, i => Text(if i % 2 == 0 { "/api" } else { "/assets" })),
        Array::makei(4, _ => Integer(if batch_index == 3 { 503L } else { 200L })),
        Array::makei(4, i => {
          if i == 0 {
            Null
          } else {
            Real((i * 3).to_double())
          }
        }),
      ]),
    )
  }
  let file = @orc.OrcFile::open(
    writer.finish(metadata=Map([("producer", b"log-export-example")])),
  )
  let scanner = file.scan(
    columns=Some(["request_id", "route"]),
    predicate=Compare("status", GreaterEqual, Integer(500L)),
    batch_rows=3,
    trust_statistics=true,
  )
  let mut rows = 0
  while scanner.next() is Some(batch) {
    assert_eq(batch.schema().columns().length(), 2)
    for row = 0; row < batch.row_count(); row = row + 1 {
      assert_true(
        match batch.cell(row, "request_id") {
          Integer(n) => n >= 12L
          _ => false
        },
      )
    }
    rows += batch.row_count()
  }
  assert_eq(rows, 4)
  assert_eq(scanner.metrics().stripes_skipped, 3)
  println(
    "logs: exported 16 typed records; selected 4 error requests; skipped 3 trusted stripes",
  )
}
