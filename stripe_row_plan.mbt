///|
#derive(Eq, Debug)
pub(all) struct StripeRowPlan {
  stripe : Int32
  first_row : Int32
  row_count : Int32
  streams : Array[StreamRange]
}

///|
pub extend StripeRowPlan with Eq::{equal, not_equal}

///|
pub extend StripeRowPlan with @debug.Debug::{to_repr}

///|
/// Plan physical streams for intersecting stripes and the row slice in each.
pub fn OrcFile::plan_rows(
  self : OrcFile,
  row_start : Int32,
  row_count : Int32,
  columns : Array[String],
  include_indexes~ : Bool = false,
) -> Array[StripeRowPlan] raise OrcError {
  if row_start < 0 ||
    row_count < 0 ||
    row_start > self.rows ||
    row_count > self.rows - row_start {
    raise Invalid("plan row range", row_start)
  }
  let seen : Map[String, Bool] = Map([])
  for name in columns {
    let id = self.schema.index(name)
    if seen.contains(name) {
      raise Invalid("duplicate projection column", id)
    }
    seen[name] = true
  }
  let result = []
  if row_count == 0 {
    return result
  }
  let end = row_start + row_count
  let mut offset = 0
  for index, stripe in self.stripes {
    let stripe_end = add(offset, stripe.rows)
    let lo = row_start.max(offset)
    let hi = end.min(stripe_end)
    if lo < hi {
      result.push({
        stripe: index,
        first_row: lo - offset,
        row_count: hi - lo,
        streams: self.plan_stripe(index, columns, include_indexes~),
      })
    }
    if stripe_end >= end {
      break
    }
    offset = stripe_end
  }
  result
}
