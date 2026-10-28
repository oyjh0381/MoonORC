///|
priv struct EncodedColumn {
  encoding : Int32
  dictionary_size : Int32
  streams : Array[(Int32, Bytes)]
}

///|
/// Writer deliberately emits RLEv1 DIRECT, allowed in ORC 0.12 files.
fn encode_column(kind : Kind, values : Array[Cell]) -> EncodedColumn {
  let streams : Array[(Int32, Bytes)] = []
  let present = values.map(x => x != Null)
  if present.any(x => !x) {
    streams.push((0, encode_bits(present)))
  }
  let values = values.filter(x => x != Null)
  if kind == String && values.length() >= 4 {
    let unique : Map[String, Bool] = Map([])
    for v in values {
      if v is Text(s) {
        unique[s] = true
      }
    }
    if unique.length() <= values.length() / 2 {
      let dictionary = unique.keys().collect()
      dictionary.sort_by(utf8_compare)
      let ids : Map[String, Int32] = Map([])
      let data = output()
      let lengths : Array[UInt64] = []
      for i = 0; i < dictionary.length(); i = i + 1 {
        let raw = @utf8.encode(dictionary[i])
        ids[dictionary[i]] = i
        lengths.push(raw.length().to_uint64())
        data.raw(raw)
      }
      let references = values.map(v => {
        match v {
          Text(s) => ids.get(s).unwrap().to_uint64()
          _ => 0UL
        }
      })
      streams.push((1, encode_rle1(references, false)))
      streams.push((2, encode_rle1(lengths, false)))
      streams.push((3, data.finish()))
      return { encoding: 1, dictionary_size: dictionary.length(), streams, }
    }
  }
  let raw = output()
  match kind {
    Boolean =>
      streams.push(
        (
          1,
          encode_bits(
            values.map(v => {
              match v {
                Bool(x) => x
                _ => false
              }
            }),
          ),
        ),
      )
    Byte => {
      for v in values {
        if v is Integer(x) {
          raw.byte(x.to_int())
        }
      }
      streams.push((1, encode_bytes(raw.finish())))
    }
    Short | Int | Long | Date => {
      let ints = values.map(v => {
        match v {
          Integer(n) => n.reinterpret_as_uint64()
          Days(n) => n.to_int64().reinterpret_as_uint64()
          _ => 0UL
        }
      })
      streams.push((1, encode_rle1(ints, true)))
    }
    Float | Double => {
      for v in values {
        if v is Real(n) {
          if kind == Float {
            raw.little(
              Float::from_double(n).reinterpret_as_uint().to_uint64(),
              4,
            )
          } else {
            raw.little(n.reinterpret_as_uint64(), 8)
          }
        }
      }
      streams.push((1, raw.finish()))
    }
    String | Binary => {
      let lengths : Array[UInt64] = []
      for v in values {
        let bytes = match v {
          Text(s) => @utf8.encode(s)
          Blob(b) => b
          _ => b""
        }
        raw.raw(bytes)
        lengths.push(bytes.length().to_uint64())
      }
      streams.push((1, raw.finish()))
      streams.push((2, encode_rle1(lengths, false)))
    }
  }
  { encoding: 0, dictionary_size: 0, streams, }
}
