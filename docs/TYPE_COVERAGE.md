# Standard ORC type coverage and implementation sequence

Version 0.2.0, 2026-11-06. Earlier 0.1.0 does not contain the
new DECIMAL/CHAR/VARCHAR APIs. This matrix describes actual capabilities, not
full ORC compliance. Source: [Apache ORC v1 specification](https://orc.apache.org/specification/ORCv1/).

| Standard type family | Read | Write | Scope / evidence |
|---|---|---|---|
| BOOLEAN; BYTE, SHORT, INT, LONG | yes | yes | nullable; full Int64; RLEv1/v2 reader |
| FLOAT, DOUBLE | yes | yes | IEEE values, explicit Float narrowing |
| STRING, BINARY | yes | yes | direct, string dictionaries; no binary dictionary |
| DATE | yes | yes | Unix days; documented calendar boundary |
| DECIMAL(p,s) | **new** | **new** | p=1..38, s=0..p; exact coefficients; DIRECT/V2 reader, DIRECT writer |
| VARCHAR(n) | **new** | **new** | 1..65535 Unicode code points; no silent truncation |
| CHAR(n) | **new** | **new** | 1..65535 code points; normalized API, file-level ASCII space padding |
| TIMESTAMP, TIMESTAMP_INSTANT | planned | planned | epoch, nanoseconds, timezone and legacy calendar validation required |
| STRUCT nesting, LIST, MAP, UNION | planned | planned | root remains flat STRUCT today; child type IDs/streams not implemented |

## Current foundational additions

`Kind::Decimal(precision, scale)` retains both parameters in the ORC Type
protobuf (fields 5/6). `Cell::DecimalNumber(DecimalValue)` uses private exact
signed coefficient text and scale. `DecimalValue::parse(text,p,s)` accepts
plain decimal notation, pads an insufficient fractional part, rejects excessive
scale/precision, exponent and invalid input. No rounding or Double conversion.
`to_string()` emits fixed scale; negative zero becomes zero. Schema equality,
alignment, projection, sort and exact decimal predicate evaluation retain types.

The DATA stream uses bounded base-128 zigzag encoding independent of Int64;
SECONDARY is signed scale RLE. Read scales -38..38 can be exactly adjusted to
schema scale; lossy adjustment, overflow, truncated and >19-byte varints fail.
Historical unbounded decimals and scale outside that range remain unsupported.
With D<=38, arithmetic is O(D) per small multiply/divide, decimal codec O(D²)
per value with fixed upper bound; retained decimal text O(rows*D). Large input
is still constrained by file, row, decoded byte and protobuf limits.

`Kind::Varchar(n)` and `Kind::Char(n)` preserve Type.maximumLength (field 4).
Use `Cell::Text`: VARCHAR preserves spaces; CHAR API values exclude trailing
ASCII spaces (reject on construction), decoder removes padding, writer pads
to declared code-point width. Spaces are therefore not separately observable
as CHAR payload; choose VARCHAR/STRING when trailing spaces are significant.
Supplementary Unicode characters count once. Overlong input is rejected, not
truncated; canonical normalization is not performed. CHAR padding expansion is
counted in the decoded byte budget before encoding. Both direct and dictionary
representations share these rules. String operations take O(UTF8 bytes), plus
CHAR padding width. Decimal/CHAR min/max pruning is conservative: bounds are
omitted/ignored, while exact predicates still evaluate rows. No unverified
decimal or padded-text statistics are used to skip data.

## Compatibility-first roadmap

The next core deliverables are ordered below. Higher-level contracts, row
provenance, sorting and deduplication remain optional utilities; new development
priority is type/encoding coverage. Plans are not implemented capability claims.

1. **Time scalar phase**: separate local TIMESTAMP from UTC TIMESTAMP_INSTANT,
   retain Int64 seconds and nanoseconds, implement secondary nanos compression,
   stripe writerTimezone and epoch handling. Exit gate: Apache ORC bidirectional
   fixtures before/after epoch, nanosecond extremes, timezone/DST and pre-calendar
   cases; explicitly reject unsupported zones rather than shift values silently.
2. **Nested STRUCT/LIST phase**: recursive schema with preorder type IDs,
   depth/node/expanded element budgets, parent-present suppression, list LENGTH
   and child cardinality. Exit gate: nullable parent vs empty list vs null child,
   arbitrary child order, multi-stripe projection, independent C++ roundtrip.
3. **MAP/UNION phase**: key/value stream counts, tagged child streams and exact
   schema retention. Exit gate: empty/null collection, null elements, tags out
   of bounds, mismatched child counts, nested roundtrips and malformed budgets.
4. **Additional compression and seek phase**: independently validate Snappy,
   LZ4/ZSTD framing; row-group positioning only after stream/index compatibility
   is proven. Exit gate: codec-specific refusal tests, independent files and
   byte accounting. Do not label a codec supported because it was enumerated.

## Reproduction

```sh
moon run examples/format_types --target native --deny-warn
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
python scripts/interop_types.py _build/native/debug/build/cmd/main/main.exe
```

Install the pinned development oracle with `scripts/requirements-interop.txt`.
On Windows use the README's wrapper. The independent script generates synthetic
305-row datasets across NONE/ZLIB and direct/dictionary text, checks decimal
38-digit extrema and scales 0/8/38, empty/all-null schemas, rewritten metadata
parameters and MoonBit-created output with Apache ORC. Original regression
script `scripts/interop.py verify ...` remains required. Fixtures are generated
temporarily, third-party source is not copied or shipped.
