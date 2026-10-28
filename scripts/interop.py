"""Original synthetic ORC fixtures and independent Apache ORC oracle via pyorc."""
from pathlib import Path
import argparse
import datetime
import json
import math
import subprocess
import tempfile
import pyorc

SCHEMA = "struct<id:bigint,label:string,value:double,ok:boolean,small:tinyint,day:date,blob:binary,ratio:float>"


def rows():
    for i in range(600):
        yield (None if i % 11 == 0 else i - 300,
               None if i % 17 == 0 else ["hello", "你好", "", "same"][i % 4],
               None if i % 7 == 0 else i * .25,
               None if i % 3 == 0 else i % 2 == 0,
               (i % 256) - 128,
               datetime.date(1970, 1, 1) + datetime.timedelta(days=i - 300),
               bytes([i % 256, 0, 255]), float(i * .5))


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    for compression in (pyorc.CompressionKind.NONE, pyorc.CompressionKind.ZLIB):
        name = "plain" if compression == pyorc.CompressionKind.NONE else "zlib"
        with (directory / f"{name}.orc").open("wb") as f:
            writer = pyorc.Writer(f, SCHEMA, compression=compression,
                                 stripe_size=4096, row_index_stride=1000,
                                 dict_key_size_threshold=1.0)
            writer.writerows(rows())
            writer.set_user_metadata(source=b"original-pyorc-fixture")
            writer.close()
    print("generated original Apache ORC fixtures")
    with (directory / "extreme.orc").open("wb") as f:
        writer = pyorc.Writer(f, "struct<x:bigint,s:string,f:double>", compression=pyorc.CompressionKind.ZLIB, row_index_stride=1000)
        data = [(-(2**63), "\U00010000", -0.), (2**63-1, "\ue000", float('inf')), (None, "", float('nan'))]
        data += [(2000 + (1000000 if i == 13 else i * 5), "v" + str(i), i * -.25) for i in range(1200)]
        writer.writerows(data)
        writer.close()
    with (directory / "nested.orc").open("wb") as f:
        writer = pyorc.Writer(f, "struct<x:array<int>>", compression=pyorc.CompressionKind.NONE)
        writer.write(([1, 2],))
        writer.close()


def normalized(value):
    if value is None or isinstance(value, bool) or isinstance(value, str):
        return value
    if isinstance(value, datetime.date):
        return (value - datetime.date(1970, 1, 1)).days
    if isinstance(value, int):
        return str(value)
    if isinstance(value, bytes):
        return list(value)
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Infinity" if value > 0 else "-Infinity"
    if value == 0. and math.copysign(1., value) < 0:
        return "-0"
    return value


def verify(cli):
    cli = cli.resolve()
    def run(*args, success=True):
        result = subprocess.run([str(cli), *map(str,args)], capture_output=True, text=True, encoding="utf-8")
        if success and result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        if not success and result.returncode == 0:
            raise AssertionError("invalid operation unexpectedly succeeded")
        return result.stdout
    with tempfile.TemporaryDirectory(prefix="moonorc-oracle-") as temp:
        directory = Path(temp)
        generate(directory)
        for name in ("plain", "zlib", "extreme"):
            source = directory / f"{name}.orc"
            result = json.loads(run("read", source))
            with source.open("rb") as f:
                reader = pyorc.Reader(f)
                expected = [[normalized(v) for v in row] for row in reader]
            assert result["rows"] == expected, name
            target = directory / f"{name}-rewritten.orc"
            run("rewrite", source, target)
            with target.open("rb") as f:
                actual = [[normalized(v) for v in row] for row in pyorc.Reader(f)]
            assert actual == expected, name + " reverse"
        generated = directory / "moon.orc"
        run("demo", generated)
        check(generated)
        before = generated.read_bytes()
        run("demo", generated, success=False)
        assert generated.read_bytes() == before
        run("read", directory / "nested.orc", success=False)
    print("PASS: independent Apache ORC bidirectional types, nulls, dictionaries, dates, stripes and refusal checks")


def check(path):
    with path.open("rb") as f:
        actual = list(pyorc.Reader(f))
    assert actual[0] == (-(2**63), "你好", -0., True)
    assert actual[1] == (None, "", None, False)
    assert actual[2] == (2**63 - 1, None, 1.25, None)
    assert math.copysign(1., actual[0][2]) == -1.
    print("Apache ORC independently read MoonORC nullable multi-stripe output")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["generate", "check", "verify"])
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    {"generate": generate, "check": check, "verify": verify}[args.action](args.path)
