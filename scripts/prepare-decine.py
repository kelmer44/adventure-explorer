#!/usr/bin/env python3
"""Extract Una Aventura de Cine's Spanish CD cabinets into a browseable folder."""
import argparse
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import tempfile


def members(cabinet):
    with cabinet.open('rb') as stream:
        header = stream.read(36)
        if len(header) != 36 or header[:4] != b'MSCF':
            raise ValueError(f'Invalid cabinet: {cabinet}')
        stream.seek(struct.unpack_from('<I', header, 16)[0])
        for _ in range(struct.unpack_from('<H', header, 28)[0]):
            record = stream.read(16)
            if len(record) != 16:
                raise ValueError('Truncated cabinet directory')
            name = bytearray()
            while True:
                char = stream.read(1)
                if not char:
                    raise ValueError('Truncated cabinet filename')
                if char == b'\0':
                    break
                name += char
            filename = name.decode('utf-8' if struct.unpack_from('<H', record, 14)[0] & 0x80 else 'cp1252')
            path = PurePosixPath(filename.replace('\\', '/'))
            if path.is_absolute() or '..' in path.parts or ':' in filename:
                raise ValueError(f'Unsafe cabinet filename: {filename}')
            yield path


def prepare(source, output):
    source, output = source.resolve(), output.resolve()
    if source == output or source in output.parents or output in source.parents:
        raise ValueError('Choose a separate output folder outside the source media')
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError('Output must be new or empty')
    extractor = shutil.which('cabextract')
    if not extractor:
        raise ValueError('Install cabextract first')
    files = {p.name.lower(): p for p in source.iterdir() if p.is_file()}
    cabinets = [files.get(f'data{i:02}.cab') for i in (1, 2)]
    if not all(cabinets):
        raise ValueError('Expected data01.cab and data02.cab in the source folder')
    allowed = {'animaciones', 'fondos', 'mascaras', 'sonidos', 'textos', 'mapas', 'script', 'data'}
    # Validate all paths before invoking the extractor; stage atomically on failure.
    for cab in cabinets:
        list(members(cab))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='decine-', dir=output.parent) as temp:
        staging = Path(temp)
        subprocess.run([extractor, '-q', '-e', 'WINDOWS-1252', '-d', str(staging),
                        *(str(p) for p in cabinets)], check=True)
        if not (staging / 'Textos' / 'OBJETOS.NKR').exists() and not any(
            p.name.lower() == 'objetos.nkr' for p in staging.rglob('*')):
            raise ValueError('Cabinets do not contain the expected Movie Adventure data')
        output.mkdir(exist_ok=True)
        for folder in staging.iterdir():
            if folder.is_dir() and folder.name.lower() in allowed:
                shutil.move(str(folder), output / folder.name)
    print(f'Ready to open in Adventure Explorer: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        prepare(args.source, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
