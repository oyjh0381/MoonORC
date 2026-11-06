"""Independent Apache ORC scalar-type oracle; synthetic data only."""
from pathlib import Path
from decimal import Decimal, localcontext
import json
import subprocess
import sys
import tempfile
import pyorc


def verify(cli):
    cli = cli.resolve()
    def run(*args):
        p = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True, encoding='utf8')
        assert p.returncode == 0, p.stdout + p.stderr
        return p.stdout

    schema = 'struct<amount:decimal(38,8),code:varchar(4),tag:char(3),whole:decimal(38,0),tiny:decimal(38,38)>'
    with tempfile.TemporaryDirectory(prefix='moonorc-types-') as temp, localcontext() as context:
        context.prec = 60
        root = Path(temp)
        values = [Decimal('999999999999999999999999999999.99999999'),
                  Decimal('-999999999999999999999999999999.99999999'),
                  Decimal('-0.00000001'), Decimal('0.00000000'), None]
        rows = [(values[i % 5], ['中😀', '', 'abcd', 'é', None][i % 5],
                 ['中😀', '', 'abc', 'é', None][i % 5],
                 [Decimal('9' * 38), Decimal('-' + '9' * 38), Decimal(0), Decimal(1), None][i % 5],
                 [Decimal('0.' + '9' * 38), Decimal('-0.' + '0' * 37 + '1'), Decimal(0), Decimal('0.5'), None][i % 5])
                for i in range(305)]
        for codec in [pyorc.CompressionKind.NONE, pyorc.CompressionKind.ZLIB]:
            for dictionary in [0.0, 1.0]:
                source = root / f'{codec.name}-{dictionary}.orc'
                with source.open('wb') as stream:
                    writer = pyorc.Writer(stream, schema, compression=codec, dict_key_size_threshold=dictionary, stripe_size=4096)
                    writer.writerows(rows)
                    writer.close()
                with source.open('rb') as stream:
                    original = list(pyorc.Reader(stream))
                expected = [[format(v, 'f') if isinstance(v, Decimal) else v for v in row] for row in original]
                for row in expected:
                    if row[2] is not None: row[2] = row[2].rstrip(' ')
                assert json.loads(run('read', source))['rows'] == expected
                target = source.with_suffix('.rewritten.orc')
                run('rewrite', source, target)
                with target.open('rb') as stream:
                    reader = pyorc.Reader(stream)
                    assert str(reader.schema) == schema
                    actual = list(reader)
                    assert actual == original, next(((x,y) for x,y in zip(actual,original) if x != y),(len(actual),len(original)))
        # A MoonBit-created file, independently consumed by Apache ORC.
        target = root / 'native.orc'
        run('demo-format', target)
        with target.open('rb') as stream:
            reader = pyorc.Reader(stream)
            assert str(reader.schema) == 'struct<amount:decimal(38,8),code:varchar(4),tag:char(3)>'
            result = list(reader)
            assert [(a,b,c.rstrip(' ') if c is not None else None) for a,b,c in result] == [(values[0], '中😀', 'ABC'), (values[2], '', '中'), (None, None, None)]
        # Zero non-null values and zero rows still retain precision/scale/length.
        for rows_empty in [[], [(None,) * 5] * 4]:
            source = root / f'empty-{len(rows_empty)}.orc'
            with source.open('wb') as stream:
                w = pyorc.Writer(stream, schema); w.writerows(rows_empty); w.close()
            assert len(json.loads(run('read', source))['rows']) == len(rows_empty)
            target = source.with_suffix('.rewritten.orc')
            run('rewrite', source, target)
            with target.open('rb') as stream:
                reader = pyorc.Reader(stream)
                assert str(reader.schema) == schema and list(reader) == rows_empty
    print('PASS: decimal38 (scale 0/8/38), CHAR/VARCHAR Unicode, direct/dictionary, NONE/ZLIB, null/empty schemas and independent native output')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
