///|
fn split_blobs(
  raw : Bytes,
  lengths : Array[UInt64],
  limits : Limits,
) -> Array[Bytes] raise OrcError {
  let c = input(raw)
  let out : Array[Bytes] = []
  for length in lengths {
    let n = host(length)
    if n > limits.max_decoded_bytes {
      raise Limit("string/binary cell length")
    }
    out.push(c.take(n))
  }
  if c.pos != c.end {
    raise Invalid("trailing string data", c.pos)
  }
  out
}

///|
fn OrcFile::decode_column(
  self : OrcFile,
  stripe : Stripe,
  index : Int32,
) -> Array[Cell] raise OrcError {
  let id = index + 1
  let rows = stripe.info.rows
  if rows > self.limits.max_rows {
    raise Limit("stripe rows")
  }
  let present = match self.stream(stripe, id, 0) {
    Some(raw) => decode_bits(raw, rows)
    None => Array::make(rows, true)
  }
  let count = present.filter(x => x).length()
  let kind = self.schema.columns[index].kind
  let encoding = stripe.encodings[id]
  if (kind == Boolean || kind == Byte || kind == Float || kind == Double) &&
    encoding.kind != 0 {
    raise Unsupported("non-direct boolean/byte/floating encoding")
  }
  let raw = self.required_stream(stripe, id, 1, count)
  let nonnull : Array[Cell] = match kind {
    Boolean => decode_bits(raw, count).map(x => Bool(x))
    Byte =>
      decode_bytes(raw, count)
      .to_array()
      .map(x => {
        Integer(
          (if x.to_int() < 128 { x.to_int() } else { x.to_int() - 256 }).to_int64(),
        )
      })
    Short | Int | Long | Date => {
      if encoding.kind == 1 || encoding.kind == 3 {
        raise Unsupported("dictionary numeric encoding")
      }
      decode_integers(raw, count, true, encoding.kind).map(bits => {
        let value = bits.reinterpret_as_int64()
        if kind == Date {
          if value < -141427L &&
            number(parse_proto(self.footer, self.limits), 11, 0UL) != 2UL {
            raise Unsupported("pre-Gregorian date in hybrid calendar file")
          }
          if value < -2147483648L || value > 2147483647L {
            raise Invalid("date day range", id)
          }
          Days(value.to_int())
        } else {
          Integer(value)
        }
      })
    }
    Float | Double => {
      if raw.length() != mul(count, if kind == Float { 4 } else { 8 }) {
        raise Invalid("floating column byte count", id)
      }
      let c = input(raw)
      Array::makei(count, _ => {
        Real(
          if kind == Double {
            c.little(8).reinterpret_as_double()
          } else {
            Float::reinterpret_from_uint(c.little(4).to_uint()).to_double()
          },
        )
      })
    }
    String | Binary => {
      let dictionary = encoding.kind == 1 || encoding.kind == 3
      if dictionary && kind == Binary {
        raise Unsupported("binary dictionary")
      }
      let n = if dictionary { encoding.dictionary_size } else { count }
      if n > self.limits.max_rows {
        raise Limit("dictionary entries")
      }
      let lengths = decode_integers(
        self.required_stream(stripe, id, 2, n),
        n,
        false,
        encoding.kind,
      )
      let contents = if dictionary {
        self.required_stream(stripe, id, 3, n)
      } else {
        raw
      }
      let entries = split_blobs(contents, lengths, self.limits).map(b => {
        if kind == String {
          Text(decode_text(b))
        } else {
          Blob(b)
        }
      })
      if dictionary {
        decode_integers(raw, count, false, encoding.kind).map(n => {
          let n = host(n)
          if n >= entries.length() {
            raise Invalid("dictionary index", id)
          }
          entries[n]
        })
      } else {
        entries
      }
    }
  }
  let mut at = 0
  let values = present.map(p => {
    if p {
      let value = nonnull[at]
      at += 1
      value
    } else {
      Null
    }
  })
  for value in values {
    value.validate(kind)
  }
  values
}

///|
pub fn OrcFile::read_stripe(
  self : OrcFile,
  index : Int32,
  columns~ : Array[String]? = None,
) -> Batch raise OrcError {
  let stripe = self.stripe(index)
  let names = columns.unwrap_or_else(() => self.schema.columns.map(c => c.name))
  let descriptors = names.map(name => {
    self.schema.columns[self.schema.index(name)]
  })
  let schema = Schema::new(descriptors, limits=self.limits)
  if mul(mul(stripe.info.rows, names.length()), 8) >
    self.limits.max_decoded_bytes {
    raise Limit("projected stripe cell storage")
  }
  let values = names.map(name => {
    self.decode_column(stripe, self.schema.index(name))
  })
  Batch::new(schema, values, limits=self.limits)
}
