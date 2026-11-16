///|
/// Exact fixed-scale decimal, up to 38 significant coefficient digits.
#derive(Debug, Eq)
pub struct DecimalValue {
  priv coefficient : String
  priv scale : Int32
}

///|
pub extend DecimalValue with @debug.Debug::{to_repr}

///|
pub extend DecimalValue with Eq::{equal, not_equal}

///|
fn strip_digits(s : String) -> String {
  let mut i = 0
  while i < s.length() - 1 && s[i] == '0' {
    i += 1
  }
  s[i:].to_owned()
}

///|
fn decimal_kind(precision : Int32, scale : Int32) -> Unit raise OrcError {
  if precision < 1 || precision > 38 || scale < 0 || scale > precision {
    raise Invalid(
      "decimal requires 1<=precision<=38 and 0<=scale<=precision", 0,
    )
  }
}

///|
/// Parse plain fixed-point text without rounding, exponent or floating conversion.
pub fn DecimalValue::parse(
  text : String,
  precision : Int32,
  scale : Int32,
) -> DecimalValue raise OrcError {
  decimal_kind(precision, scale)
  if text.is_empty() || text.length() > 80 {
    raise Invalid("decimal text length", 0)
  }
  let negative = text[0] == '-'
  let start = if negative || text[0] == '+' { 1 } else { 0 }
  let out = StringBuilder()
  let mut dot = false
  let mut whole = 0
  let mut fraction = 0
  for i = start; i < text.length(); i = i + 1 {
    let c = text[i]
    if c == '.' && !dot {
      dot = true
    } else {
      if c < '0' || c > '9' {
        raise Invalid("decimal digit", i)
      }
      if dot {
        fraction += 1
      } else {
        whole += 1
      }
      out.write_char(c.to_int().to_char().unwrap())
    }
  }
  if whole == 0 || (dot && fraction == 0) || fraction > scale {
    raise Invalid("decimal scale; rounding is not implicit", 0)
  }
  for i = fraction; i < scale; i = i + 1 {
    out.write_string("0")
  }
  let digits = strip_digits(out.to_string())
  if digits.length() > precision {
    raise Invalid("decimal precision overflow", 0)
  }
  {
    coefficient: (if negative && digits != "0" { "-" } else { "" }) + digits,
    scale,
  }
}

///|
pub fn DecimalValue::to_string(self : DecimalValue) -> String {
  let negative = self.coefficient[0] == '-'
  let mut digits = if negative {
    self.coefficient[1:].to_owned()
  } else {
    self.coefficient
  }
  while digits.length() <= self.scale {
    digits = "0" + digits
  }
  let point = digits.length() - self.scale
  (if negative { "-" } else { "" }) +
  (if self.scale == 0 {
    digits
  } else {
    digits[:point].to_owned() + "." + digits[point:].to_owned()
  })
}

///|
// Small decimal-string arithmetic bounds all intermediates to <=40 digits.
fn decimal_mul_add(digits : String, factor : Int32, carry : Int32) -> String {
  let result : Array[String] = []
  let mut carry = carry
  for i = digits.length() - 1; i >= 0; i = i - 1 {
    let n = (digits[i].to_int() - 48) * factor + carry
    result.push((n % 10).to_string())
    carry = n / 10
  }
  while carry > 0 {
    result.push((carry % 10).to_string())
    carry = carry / 10
  }
  let b = StringBuilder()
  for i = result.length() - 1; i >= 0; i = i - 1 {
    b.write_string(result[i])
  }
  strip_digits(b.to_string())
}

///|
fn decimal_div(digits : String, divisor : Int32) -> (String, Int32) {
  let b = StringBuilder()
  let mut remainder = 0
  for i = 0; i < digits.length(); i = i + 1 {
    let n = remainder * 10 + digits[i].to_int() - 48
    b.write_string((n / divisor).to_string())
    remainder = n % divisor
  }
  (strip_digits(b.to_string()), remainder)
}

///|
fn encode_decimal(value : DecimalValue, out : Output) -> Unit {
  let negative = value.coefficient[0] == '-'
  let magnitude = if negative {
    value.coefficient[1:].to_owned()
  } else {
    value.coefficient
  }
  // zigzag(-m) = 2*(m-1)+1. Borrow using fixed-length decimal digits.
  let mut encoded = decimal_mul_add(magnitude, 2, 0)
  if negative {
    let chars = encoded.to_array()
    let mut i = chars.length() - 1
    while chars[i] == '0' {
      chars[i] = '9'
      i -= 1
    }
    chars[i] = (chars[i].to_int() - 1).to_char().unwrap()
    encoded = strip_digits(String::from_array(chars))
  }
  while encoded != "0" {
    let (quotient, remainder) = decimal_div(encoded, 128)
    out.byte(remainder | (if quotient == "0" { 0 } else { 128 }))
    encoded = quotient
  }
  if magnitude == "0" {
    out.byte(0)
  }
}

///|
fn decode_decimal(
  c : Input,
  source_scale : Int64,
  precision : Int32,
  scale : Int32,
) -> DecimalValue raise OrcError {
  if source_scale < -38L || source_scale > 38L {
    raise Unsupported("decimal source scale outside -38..38")
  }
  let groups : Array[Int32] = []
  let mut done = false
  for i = 0; i < 19; i = i + 1 {
    let b = c.byte()
    groups.push(b & 127)
    if b < 128 {
      done = true
      break
    }
  }
  if !done {
    raise Invalid("decimal varint exceeds 19 bytes", c.pos)
  }
  let mut digits = "0"
  for i = groups.length() - 1; i >= 0; i = i - 1 {
    digits = decimal_mul_add(digits, 128, groups[i])
  }
  let (half, sign) = decimal_div(digits, 2)
  digits = if sign == 1 { decimal_mul_add(half, 1, 1) } else { half }
  let shift = scale - source_scale.to_int()
  if shift >= 0 {
    if digits != "0" {
      if digits.length() + shift > precision {
        raise Invalid("decimal precision overflow", c.pos)
      }
      for i = 0; i < shift; i = i + 1 {
        digits += "0"
      }
    }
  } else {
    for i = 0; i < -shift; i = i + 1 {
      let (q, r) = decimal_div(digits, 10)
      if r != 0 {
        raise Invalid("decimal rescale loses precision", c.pos)
      }
      digits = q
    }
  }
  if digits.length() > precision {
    raise Invalid("decimal precision overflow", c.pos)
  }
  {
    coefficient: (if sign == 1 && digits != "0" { "-" } else { "" }) + digits,
    scale,
  }
}

///|
fn compare_decimal(a : DecimalValue, b : DecimalValue) -> Int32 {
  let na = a.coefficient[0] == '-'
  let nb = b.coefficient[0] == '-'
  if na != nb {
    return if na { -1 } else { 1 }
  }
  let mut x = if na { a.coefficient[1:].to_owned() } else { a.coefficient }
  let mut y = if nb { b.coefficient[1:].to_owned() } else { b.coefficient }
  if a.scale < b.scale {
    for i = a.scale; i < b.scale; i = i + 1 {
      x += "0"
    }
  }
  if b.scale < a.scale {
    for i = b.scale; i < a.scale; i = i + 1 {
      y += "0"
    }
  }
  x = strip_digits(x)
  y = strip_digits(y)
  let cmp = if x.length() != y.length() {
    x.length().compare(y.length())
  } else {
    x.compare(y)
  }
  if na {
    -cmp
  } else {
    cmp
  }
}
