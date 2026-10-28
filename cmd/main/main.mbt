///|
fn cell_json(cell : @orc.Cell) -> Json {
  match cell {
    Null => Json::null()
    Bool(x) => Json::boolean(x)
    Integer(n) => Json::string(n.to_string())
    Days(n) => Json::number(n.to_double())
    Text(s) => Json::string(s)
    Blob(b) => Json::array(b.to_array().map(x => Json::number(x.to_double())))
    Real(x) =>
      if x.is_nan() {
        Json::string("NaN")
      } else if x.is_pos_inf() {
        Json::string("Infinity")
      } else if x.is_neg_inf() {
        Json::string("-Infinity")
      } else if x == 0.0 && x.reinterpret_as_uint64() == 0x8000000000000000UL {
        Json::string("-0")
      } else {
        Json::number(x)
      }
  }
}

///|
async fn run() -> Unit {
  let args = @env.args()
  if args.length() != 3 {
    raise Failure("usage: moonorc read FILE.orc | demo NEW.orc")
  }
  if args[1] == "demo" {
    let schema = @orc.Schema::new([
      { name: "id", kind: Long, },
      { name: "label", kind: String, },
      { name: "value", kind: Double, },
      { name: "ok", kind: Boolean, },
    ])
    let batch = @orc.Batch::new(schema, [
      [Integer(-9223372036854775808L), Null, Integer(9223372036854775807L)],
      [Text("你好"), Text(""), Null],
      [Real(-0.0), Null, Real(1.25)],
      [Bool(true), Bool(false), Null],
    ])
    @fs.write_file(
      args[2][:],
      @orc.write(batch, options={
        ..@orc.WriteOptions::default(),
        compression: Zlib,
        stripe_rows: 2,
      }),
      create_mode=CreateNew,
    )
    println("created ORC file")
  } else if args[1] == "read" {
    let limits = @orc.Limits::default()
    if @fs.file_size(args[2][:]) > limits.max_file_bytes.to_int64() {
      raise Failure("input exceeds file budget")
    }
    let file = @orc.OrcFile::open(@fs.read_file(args[2][:]).binary())
    let rows : Array[Json] = []
    for i = 0; i < file.stripes().length(); i = i + 1 {
      let batch = file.read_stripe(i)
      for r = 0; r < batch.row_count(); r = r + 1 {
        rows.push(
          Json::array(
            batch.schema().columns().map(c => cell_json(batch.cell(r, c.name))),
          ),
        )
      }
    }
    println(
      Json::object({
        "columns": Json::array(
          file.schema().columns().map(c => Json::string(c.name)),
        ),
        "rows": Json::array(rows),
      }).stringify(),
    )
  } else {
    raise Failure("unknown command")
  }
}

///|
async fn main {
  run() catch {
    @orc.OrcError::Invalid(message, offset) =>
      raise Failure("invalid ORC at \{offset}: \{message}")
    @orc.OrcError::Unsupported(message) =>
      raise Failure("unsupported ORC: \{message}")
    @orc.OrcError::Limit(message) => raise Failure("ORC limit: \{message}")
    error => raise error
  }
}
