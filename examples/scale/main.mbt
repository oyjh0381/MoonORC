///|
/// Correctness workload, not a benchmark against Apache ORC.
fn main raise {
  let schema = @orc.Schema::new([
    { name: "id", kind: Long, },
    { name: "tag", kind: String, },
  ])
  let writer = @orc.Writer::new(schema, options={
    ..@orc.WriteOptions::default(),
    compression: Zlib,
    stripe_rows: 1000,
  })
  for block = 0; block < 100; block = block + 1 {
    writer.push(
      @orc.Batch::new(schema, [
        Array::makei(1000, i => Integer((block * 1000 + i).to_int64())),
        Array::makei(1000, i => Text(["a", "b", "c"][i % 3])),
      ]),
    )
  }
  let bytes = writer.finish()
  let file = @orc.OrcFile::open(bytes)
  let scanner = file.scan(
    columns=Some(["id"]),
    predicate=Compare("id", GreaterEqual, Integer(99000L)),
    batch_rows=127,
    trust_statistics=true,
  )
  let mut count = 0
  let mut sum = 0L
  while scanner.next() is Some(batch) {
    count += batch.row_count()
    for v in batch.column("id") {
      if v is Integer(n) {
        sum += n
      }
    }
  }
  assert_eq(count, 1000)
  assert_eq(sum, 99499500L)
  assert_eq(scanner.metrics().stripes_skipped, 99)
  println(
    "scale: 100000 records, 100 stripes, 99 pruned, exact 1000-row result; bytes=\{bytes.length()}",
  )
}
