"""Verify both timestamp streams through independent Apache ORC."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

import pyorc


class ExactTime(pyorc.converters.ORCConverter):
    @staticmethod
    def to_orc(value, _timezone):
        return value

    @staticmethod
    def from_orc(seconds, nanos, _timezone):
        return seconds, nanos


def main(cli):
    cli = cli.resolve()
    def run(*args, ok=True):
        p = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True, encoding="utf8")
        assert (p.returncode == 0) == ok, p.stdout + p.stderr
        return p.stdout

    with tempfile.TemporaryDirectory(prefix="moonorc-time-") as work:
        root = Path(work)
        schema = "struct<local:timestamp,instant:timestamp with local time zone>"
        converters = {k: ExactTime for k in (pyorc.TypeKind.TIMESTAMP, pyorc.TypeKind.TIMESTAMP_INSTANT)}
        times = [(-10000, 123456789), (-2, 1000000), (0, 0), (0, 900000000),
                 (1420070400, 1000), (1749899300, 999999999), (1749899301, 10), None]
        rows = [(x, x) for x in times]
        for codec in (pyorc.CompressionKind.NONE, pyorc.CompressionKind.ZLIB):
            source = root / f"{codec.name}.orc"
            with source.open("wb") as stream:
                writer = pyorc.Writer(stream, schema, converters=converters, compression=codec)
                writer.writerows(rows)
                writer.close()
            with source.open("rb") as stream:
                assert list(pyorc.Reader(stream, converters=converters)) == rows
            expected = [[None if v is None else dict(seconds=str(v[0]), nanos=v[1]) for v in row] for row in rows]
            assert json.loads(run("read", source))["rows"] == expected
            if codec == pyorc.CompressionKind.NONE:
                # A UTC reader must not silently interpret wall time from a
                # non-UTC writer. Keep protobuf field and stripe sizes intact.
                original = source.read_bytes()
                for zone in (b"UTC", b"GMT"):
                    marker = b"\x1a\x03" + zone
                    if marker in original:
                        alien = root / "unsupported-zone.orc"
                        alien.write_bytes(original.replace(marker, b"\x1a\x03EST"))
                        run("read", alien, ok=False)
                        break
                else:
                    raise AssertionError("expected UTC writerTimezone in stripe footer")
            output = source.with_suffix(".rewritten.orc")
            run("rewrite", source, output)
            with output.open("rb") as stream:
                reader = pyorc.Reader(stream, converters=converters)
                assert str(reader.schema) == schema and list(reader) == rows
    print("PASS: Apache ORC TIMESTAMP and TIMESTAMP_INSTANT both directions, exact nanoseconds and nulls")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
