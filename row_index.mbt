///| Row-group statistics are exposed separately from stream positions. This API

///|
/// does not promise row-group seek or selective decompression within a stripe.
#derive(Debug, Eq)
pub(all) struct RowGroupInfo {
  row_start : Int32
  row_count : Int32
  positions : Array[UInt64]
  statistics : Statistics
}

///|
pub extend RowGroupInfo with @debug.Debug::{to_repr}

///|
pub extend RowGroupInfo with Eq::{equal, not_equal}

///|
pub fn OrcFile::row_groups(
  self : OrcFile,
  stripe_index : Int32,
  column : String,
) -> Array[RowGroupInfo] raise OrcError {
  let stripe = self.stripe(stripe_index)
  let index = self.schema.index(column)
  let stride = host(number(parse_proto(self.footer, self.limits), 8, 0UL))
  if stride == 0 {
    return []
  }
  guard self.stream(stripe, index + 1, 6) is Some(raw) else { return [] }
  let entries = blobs(parse_proto(raw, self.limits), 1)
  let expected = stripe.info.rows / stride +
    (if stripe.info.rows % stride == 0 { 0 } else { 1 })
  if entries.length() != expected {
    raise Invalid("row-index group count", stripe_index)
  }
  let groups : Array[RowGroupInfo] = []
  for i = 0; i < entries.length(); i = i + 1 {
    let fields = parse_proto(entries[i], self.limits)
    let positions : Array[UInt64] = []
    for field in fields {
      if field.id == 1 {
        match field.wire {
          Var(n) => positions.push(n)
          Data(raw) => {
            let c = input(raw)
            while c.pos < c.end {
              positions.push(c.varint())
            }
          }
          _ => raise Invalid("row-index position wire type", 0)
        }
      }
    }
    let start = mul(i, stride)
    let count = imin(stride, stripe.info.rows - start)
    let statistics = decode_statistics(
      blob(fields, 2, b""),
      self.schema.columns[index].kind,
      count,
      self.limits,
    )
    groups.push({ row_start: start, row_count: count, positions, statistics, })
  }
  groups
}
