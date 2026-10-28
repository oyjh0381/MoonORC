///|
fn bit_width(code : Int32) -> Int32 {
  if code <= 23 {
    code + 1
  } else {
    [26, 28, 30, 32, 40, 48, 56, 64][code - 24]
  }
}

///|
fn fixed_width(n : Int32) -> Int32 raise OrcError {
  for code = 0; code < 32; code = code + 1 {
    let w = bit_width(code)
    if w >= n {
      return w
    }
  }
  raise Invalid("patch width exceeds 64 bits", 0)
}

///|
/// Each packed run is byte-aligned; padding bits are not values.
fn unpack(
  c : Input,
  count : Int32,
  width : Int32,
) -> Array[UInt64] raise OrcError {
  if width < 1 || width > 64 {
    raise Invalid("packed integer width", c.pos)
  }
  let bytes = c.take((mul(count, width) + 7) / 8)
  let mut bit = 0
  Array::makei(count, _ => {
    let mut n = 0UL
    for j = 0; j < width; j = j + 1 {
      n = (n << 1) |
        ((bytes[bit / 8].to_int() >> (7 - bit % 8)) & 1).to_uint64()
      bit += 1
    }
    n
  })
}

///|
fn delta_value(
  base : UInt64,
  magnitude : UInt64,
  negative : Bool,
  signed : Bool,
) -> UInt64 raise OrcError {
  if signed {
    let ceiling = if negative {
      base - 0x8000000000000000UL
    } else {
      0x7fffffffffffffffUL - base
    }
    if magnitude > ceiling {
      raise Invalid("signed delta overflow", 0)
    }
    if negative {
      base - magnitude
    } else {
      base + magnitude
    }
  } else if negative {
    if magnitude > base {
      raise Invalid("delta underflow", 0)
    }
    base - magnitude
  } else {
    let value = base + magnitude
    if value < base {
      raise Invalid("delta overflow", 0)
    }
    value
  }
}

///|
fn decode_rle2(
  raw : Bytes,
  count : Int32,
  signed : Bool,
) -> Array[UInt64] raise OrcError {
  let c = input(raw)
  let out : Array[UInt64] = []
  while out.length() < count {
    let header = c.byte()
    let mode = header >> 6
    if mode == 0 {
      let width = ((header >> 3) & 7) + 1
      let n = (header & 7) + 3
      if n > count - out.length() {
        raise Invalid("short repeat count", c.pos)
      }
      let mut value = 0UL
      for i = 0; i < width; i = i + 1 {
        value = (value << 8) | c.byte().to_uint64()
      }
      if signed {
        value = unzig(value).reinterpret_as_uint64()
      }
      for i = 0; i < n; i = i + 1 {
        out.push(value)
      }
      continue
    }
    let code = (header >> 1) & 31
    let width = bit_width(code)
    let n = ((header & 1) << 8) + c.byte() + 1
    if n > count - out.length() {
      raise Invalid("RLEv2 run count", c.pos)
    }
    match mode {
      1 =>
        for value in unpack(c, n, width) {
          out.push(
            if signed {
              unzig(value).reinterpret_as_uint64()
            } else {
              value
            },
          )
        }
      2 => {
        let bw = c.byte()
        let pg = c.byte()
        let base_width = (bw >> 5) + 1
        let patch_width = bit_width(bw & 31)
        let gap_width = (pg >> 5) + 1
        let patch_count = pg & 31
        if width + patch_width > 64 {
          raise Invalid("patch/value width", c.pos)
        }
        let mut base = 0UL
        for i = 0; i < base_width; i = i + 1 {
          base = (base << 8) | c.byte().to_uint64()
        }
        let sign = 1UL << (base_width * 8 - 1)
        let negative = (base & sign) != 0
        let magnitude = base & (sign - 1UL)
        let base_signed = if negative {
          0L - magnitude.reinterpret_as_int64()
        } else {
          magnitude.reinterpret_as_int64()
        }
        let values = unpack(c, n, width)
        let patches = unpack(
          c,
          patch_count,
          fixed_width(gap_width + patch_width),
        )
        let mut previous = 0
        let mut extended = 0
        for entry in patches {
          let gap = host(entry >> patch_width)
          let patch = entry & ((1UL << patch_width) - 1UL)
          if gap == 255 && patch == 0UL {
            extended = add(extended, 255)
            continue
          }
          let index = add(previous, add(extended, gap))
          if index >= values.length() {
            raise Invalid("patch index outside run", c.pos)
          }
          values[index] = values[index] | (patch << width)
          previous = index
          extended = 0
        }
        if extended != 0 {
          raise Invalid("unfinished patch gap", c.pos)
        }
        for value in values {
          if signed {
            out.push(
              delta_value(
                base_signed.reinterpret_as_uint64(),
                value,
                false,
                true,
              ),
            )
          } else {
            if base_signed < 0 {
              raise Invalid("negative unsigned patched base", c.pos)
            }
            out.push(
              delta_value(
                base_signed.reinterpret_as_uint64(),
                value,
                false,
                false,
              ),
            )
          }
        }
      }
      3 => {
        let base = c.varint()
        let mut value = if signed {
          unzig(base).reinterpret_as_uint64()
        } else {
          base
        }
        out.push(value)
        let delta = unzig(c.varint())
        let magnitude = if delta < 0 {
          0UL - delta.reinterpret_as_uint64()
        } else {
          delta.reinterpret_as_uint64()
        }
        if n > 1 {
          value = delta_value(value, magnitude, delta < 0, signed)
          out.push(value)
        }
        if code == 0 {
          for i = 2; i < n; i = i + 1 {
            value = delta_value(value, magnitude, delta < 0, signed)
            out.push(value)
          }
        } else {
          if n < 2 {
            raise Invalid("variable delta requires 2 values", c.pos)
          }
          for d in unpack(c, n - 2, width) {
            value = delta_value(value, d, delta < 0, signed)
            out.push(value)
          }
        }
      }
      _ => raise Invalid("RLEv2 mode", c.pos)
    }
  }
  if c.pos != c.end {
    raise Invalid("trailing RLEv2 data", c.pos)
  }
  out
}

///|
fn decode_integers(
  raw : Bytes,
  count : Int32,
  signed : Bool,
  encoding : Int32,
) -> Array[UInt64] raise OrcError {
  if encoding < 2 {
    decode_rle1(raw, count, signed)
  } else {
    decode_rle2(raw, count, signed)
  }
}

///|
test "RLEv2 official examples cover every encoding mode" {
  assert_eq(decode_rle2(b"\x0a\x27\x10", 5, false), Array::make(5, 10000UL))
  assert_eq(
    decode_rle2(b"\x5e\x03\x5c\xa1\xab\x1e\xde\xad\xbe\xef", 4, false),
    [23713UL, 43806UL, 57005UL, 48879UL],
  )
  assert_eq(decode_rle2(b"\xc6\x09\x02\x02\x22\x42\x42\x46", 10, false), [
    2UL, 3UL, 5UL, 7UL, 11UL, 13UL, 17UL, 19UL, 23UL, 29UL,
  ])
  let patched = b"\x8e\x13\x2b\x21\x07\xd0\x1e\x00\x14\x70\x28\x32\x3c\x46\x50\x5a\x64\x6e\x78\x82\x8c\x96\xa0\xaa\xb4\xbe\xfc\xe8"
  let decoded = decode_rle2(patched, 20, false)
  assert_eq(decoded[3], 1000000UL)
  assert_eq(decoded[19], 2190UL)
}
