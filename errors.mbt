///|
#derive(Debug, Eq)
pub suberror OrcError {
  Invalid(String, Int32)
  Unsupported(String)
  Limit(String)
}

///|
pub extend OrcError with @debug.Debug::{to_repr}

///|
pub extend OrcError with Eq::{equal, not_equal}

///|
#derive(Debug, Eq)
pub(all) struct Limits {
  max_file_bytes : Int32
  max_decoded_bytes : Int32
  max_rows : Int32
  max_columns : Int32
  max_stripes : Int32
  max_fields : Int32
}

///|
pub extend Limits with @debug.Debug::{to_repr}

///|
pub extend Limits with Eq::{equal, not_equal}

///|
pub fn Limits::default() -> Limits {
  {
    max_file_bytes: 268435456,
    max_decoded_bytes: 268435456,
    max_rows: 1000000,
    max_columns: 256,
    max_stripes: 10000,
    max_fields: 100000,
  }
}

///|
fn Limits::validate(self : Limits) -> Unit raise OrcError {
  if self.max_file_bytes < 3 ||
    self.max_decoded_bytes < 0 ||
    self.max_rows < 0 ||
    self.max_columns <= 0 ||
    self.max_stripes <= 0 ||
    self.max_fields <= 0 {
    raise Invalid("invalid resource limits", 0)
  }
}

///|
fn add(a : Int32, b : Int32) -> Int32 raise OrcError {
  if a < 0 || b < 0 || a > 2147483647 - b {
    raise Limit("integer addition")
  }
  a + b
}

///|
fn mul(a : Int32, b : Int32) -> Int32 raise OrcError {
  if a < 0 || b < 0 || (b > 0 && a > 2147483647 / b) {
    raise Limit("integer multiplication")
  }
  a * b
}

///|
fn imin(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}
