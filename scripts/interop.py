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
    parser.add_argument("action", choices=["generate", "check"])
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    (generate if args.action == "generate" else check)(args.path)
