///|
pub(all) struct SchemaCompatibility {
  missing : Array[String]
  incompatible : Array[String]
  extra : Array[String]
}

///|
pub fn SchemaCompatibility::compatible(self : SchemaCompatibility) -> Bool {
  self.missing.is_empty() && self.incompatible.is_empty()
}

///|
/// Exact typed consumer contract, independent of field order. No widening/casts.
pub fn Schema::check_contract(
  self : Schema,
  required : Schema,
) -> SchemaCompatibility {
  let missing : Array[String] = []
  let incompatible : Array[String] = []
  let extra : Array[String] = []
  let wanted : Map[String, Kind] = Map([])
  for column in required.columns {
    wanted[column.name] = column.kind
  }
  for column in required.columns {
    match self.indexes.get(column.name) {
      None => missing.push(column.name)
      Some(i) =>
        if self.columns[i].kind != column.kind {
          incompatible.push(column.name)
        }
    }
  }
  for column in self.columns {
    if !wanted.contains(column.name) {
      extra.push(column.name)
    }
  }
  { missing, incompatible, extra, }
}
