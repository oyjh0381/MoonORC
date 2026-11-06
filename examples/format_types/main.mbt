///|
fn main raise {
  let schema = @orc.Schema::new([
    { name: "amount", kind: Decimal(38, 8), },
    { name: "product_code", kind: Varchar(16), },
    { name: "region", kind: Char(4), },
  ])
  let value = @orc.DecimalValue::parse(
    "123456789012345678901234567890.12345678", 38, 8,
  )
  let batch = @orc.Batch::new(schema, [
    [DecimalNumber(value), Null],
    [Text("产品😀"), Text("")],
    [Text("CN"), Null],
  ])
  let file = @orc.OrcFile::open(
    @orc.write(batch, options={
      ..@orc.WriteOptions::default(),
      compression: Zlib,
    }),
  )
  assert_eq(file.schema().columns(), schema.columns())
  assert_eq(file.read_stripe(0).column("amount"), [DecimalNumber(value), Null])
  assert_eq(file.read_stripe(0).column("region"), [Text("CN"), Null])
  assert_eq(
    file
    .scan(
      columns=Some(["product_code"]),
      predicate=Compare(
        "amount",
        Greater,
        DecimalNumber(@orc.DecimalValue::parse("0", 38, 8)),
      ),
    )
    .next()
    .unwrap()
    .column("product_code"),
    [Text("产品😀")],
  )
  println(
    "Exact DECIMAL38 and Unicode CHAR/VARCHAR schema and values survive ORC interchange",
  )
}
