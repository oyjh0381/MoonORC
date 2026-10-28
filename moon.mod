name = "local/moonorc"

version = "0.1.0"

private = true

license = "Apache-2.0"

readme = "README.md"

description = "Bounded ORC columnar record interchange and selective stripe scanning"

preferred_target = "wasm-gc"

keywords = [ "orc", "columnar", "analytics" ]

import {
  "moonbit-community/flate@0.10.0",
  "moonbitlang/async@0.22.5",
}
