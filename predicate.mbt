///|
pub(all) enum Comparison {
  Equal
  Less
  LessEqual
  Greater
  GreaterEqual
} derive(Debug, Eq)

///|
pub extend Comparison with @debug.Debug::{to_repr}

///|
pub extend Comparison with Eq::{equal, not_equal}

///|
/// Composition has SQL three-valued null semantics at row level.
pub(all) enum Predicate {
  Always(Bool)
  Compare(String, Comparison, Cell)
  IsNull(String)
  And(Predicate, Predicate)
  Or(Predicate, Predicate)
  Not(Predicate)
} derive(Debug)

///|
pub extend Predicate with @debug.Debug::{to_repr}

///|
priv enum Truth {
  Yes
  No
  Unknown
}

///|
fn Predicate::column_names(self : Predicate) -> Array[String] {
  match self {
    Always(_) => []
    Compare(name, _, _) | IsNull(name) => [name]
    And(a, b) | Or(a, b) => {
      let names = a.column_names()
      for name in b.column_names() {
        if !names.contains(name) {
          names.push(name)
        }
      }
      names
    }
    Not(a) => a.column_names()
  }
}

///|
fn Predicate::validate(
  self : Predicate,
  schema : Schema,
  depth : Int32,
) -> Unit raise OrcError {
  if depth > 64 {
    raise Limit("predicate depth")
  }
  match self {
    Always(_) => ()
    Compare(name, _, value) => {
      let kind = schema.columns[schema.index(name)].kind
      value.validate(kind)
      if kind == Binary {
        raise Unsupported("binary comparison predicate")
      }
    }
    IsNull(name) => ignore(schema.index(name))
    And(a, b) | Or(a, b) => {
      a.validate(schema, depth + 1)
      b.validate(schema, depth + 1)
    }
    Not(a) => a.validate(schema, depth + 1)
  }
}

///|
fn comparison_result(order : Int32, op : Comparison) -> Bool {
  match op {
    Equal => order == 0
    Less => order < 0
    LessEqual => order <= 0
    Greater => order > 0
    GreaterEqual => order >= 0
  }
}

///|
fn Predicate::evaluate(
  self : Predicate,
  batch : Batch,
  row : Int32,
) -> Truth raise OrcError {
  match self {
    Always(true) => Yes
    Always(false) => No
    IsNull(name) => if batch.cell(row, name) == Null { Yes } else { No }
    Compare(name, op, expected) => {
      let value = batch.cell(row, name)
      if value == Null || expected == Null {
        Unknown
      } else {
        match compare_cell(value, expected) {
          Some(order) => if comparison_result(order, op) { Yes } else { No }
          None => No
        }
      }
    }
    Not(a) =>
      match a.evaluate(batch, row) {
        Yes => No
        No => Yes
        Unknown => Unknown
      }
    And(a, b) => {
      let x = a.evaluate(batch, row)
      if x is No {
        No
      } else {
        let y = b.evaluate(batch, row)
        match (x, y) {
          (_, No) => No
          (Yes, Yes) => Yes
          _ => Unknown
        }
      }
    }
    Or(a, b) => {
      let x = a.evaluate(batch, row)
      if x is Yes {
        Yes
      } else {
        let y = b.evaluate(batch, row)
        match (x, y) {
          (_, Yes) => Yes
          (No, No) => No
          _ => Unknown
        }
      }
    }
  }
}

///|
/// False is a proof of impossibility; true includes unknown/missing statistics.
fn Predicate::may_match(
  self : Predicate,
  schema : Schema,
  stats : Array[Statistics],
  rows : Int32,
) -> Bool raise OrcError {
  if rows == 0 {
    return false
  }
  match self {
    Always(x) => x
    And(a, b) =>
      a.may_match(schema, stats, rows) && b.may_match(schema, stats, rows)
    Or(a, b) =>
      a.may_match(schema, stats, rows) || b.may_match(schema, stats, rows)
    Not(_) => true
    IsNull(name) => stats[schema.index(name)].has_null != Some(false)
    Compare(name, op, expected) => {
      if expected == Null {
        return false
      }
      let s = stats[schema.index(name)]
      if s.count == Some(0) {
        return false
      }
      let low = match s.minimum {
        Some(low) => compare_cell(low, expected)
        _ => None
      }
      let high = match s.maximum {
        Some(high) => compare_cell(high, expected)
        _ => None
      }
      match op {
        Equal => low != Some(1) && high != Some(-1)
        Less => low != Some(0) && low != Some(1)
        LessEqual => low != Some(1)
        Greater => high != Some(0) && high != Some(-1)
        GreaterEqual => high != Some(-1)
      }
    }
  }
}

///|
pub fn Batch::filter(
  self : Batch,
  predicate : Predicate,
  limits~ : Limits = Limits::default(),
) -> Batch raise OrcError {
  predicate.validate(self.schema, 0)
  let selected : Array[Int32] = []
  for row = 0; row < self.rows; row = row + 1 {
    if predicate.evaluate(self, row) is Yes {
      selected.push(row)
    }
  }
  Batch::new(
    self.schema,
    self.values.map(c => selected.map(i => c[i])),
    limits~,
  )
}

///|
test "NOT preserves unknown and pruning never confuses row predicates with statistics" {
  let s = Schema::new([{ name: "x", kind: Long, }])
  let b = Batch::new(s, [[Null, Integer(2L), Integer(8L)]])
  assert_eq(b.filter(Not(Compare("x", Less, Integer(5L)))).column("x"), [
    Integer(8L),
  ])
  assert_eq(
    b.filter(Or(IsNull("x"), Compare("x", Equal, Integer(2L)))).row_count(),
    2,
  )
  assert_true(
    !Compare("x", Greater, Integer(9L)).may_match(
      s,
      [summarize(b.values[0])],
      3,
    ),
  )
}
