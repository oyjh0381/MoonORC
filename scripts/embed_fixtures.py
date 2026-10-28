"""Convert ORIGINAL generated ORC test data to backend-independent literals.
Generated data is always excluded from effective source statistics.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
lines = ["// Generated test DATA, not effective source. See scripts/embed_fixtures.py."]
for name in ("plain", "zlib", "extreme", "nested"):
    data = (root / "fixtures" / (name + ".orc")).read_bytes()
    lines += ["///|", f"fn fixture_{name}() -> Bytes {{"]
    for start in range(0, len(data), 512):
        raw = "".join(f"\\x{x:02x}" for x in data[start:start+512])
        suffix = " +" if start + 512 < len(data) else ""
        lines.append(f'  b"{raw}"{suffix}')
    lines.append("}")
(root / "fixture_data_wbtest.mbt").write_text("\n".join(lines) + "\n", encoding="utf-8")
