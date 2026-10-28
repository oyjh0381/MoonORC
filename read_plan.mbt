///| Exact encoded file ranges, not decoded offsets or a remote downloader.
pub(all) struct StreamRange { column : String; kind : Int; offset : Int; length : Int } derive(Debug, Eq)
///|
pub extend StreamRange with @debug.Debug::{to_repr}
///|
pub extend StreamRange with Eq::{equal, not_equal}
///|
pub fn OrcFile::plan_stripe(self : OrcFile, index : Int, columns : Array[String], include_indexes? : Bool = false) -> Array[StreamRange] raise OrcError {
  let stripe = self.stripe(index)
  let ids : Map[Int, String] = Map([])
  for name in columns {
    let id = self.schema.index(name) + 1
    if ids.contains(id) { raise Invalid("duplicate projection column", id) }
    ids[id] = name
  }
  let out : Array[StreamRange] = []
  for stream in stripe.streams {
    if !include_indexes && stream.kind >= 6 { continue }
    if ids.get(stream.column) is Some(name) {
      out.push({ column: name, kind: stream.kind, offset: stream.offset, length: stream.size })
    }
  }
  out
}
///|
test "dictionary writer and range plans encode only projected columns" {
  let schema = Schema::new([{ name: "id", kind: Long }, { name: "label", kind: String }])
  let values : Array[Cell] = [Text("z"), Text("\ue000"), Text("z"), Text("\u{10000}"), Text("z"), Text("z")]
  let batch = Batch::new(schema, [Array::makei(6, i => Integer(i.to_int64())), values])
  let file = OrcFile::open(write(batch))
  assert_eq(file.stripe(0).encodings[2].kind, 1)
  assert_eq(file.read_stripe(0).column("label"), values)
  let plan = file.plan_stripe(0, ["label"])
  assert_eq(plan.length(), 3)
  assert_true(plan.all(r => r.column == "label"))
  assert_true(plan.any(r => r.kind == 3))
  assert_true(try { ignore(file.plan_stripe(0, ["id", "id"])); false } catch { _ => true })
}
