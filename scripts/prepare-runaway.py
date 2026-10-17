#!/usr/bin/env python3
"""Make a browseable Runaway data folder from installation media.

Usage: python3 scripts/prepare-runaway.py /path/to/media /path/to/empty/output
Requires cabextract. Loose files are linked; cabinet members are extracted.
The original media directory is never modified. Bink videos are not extracted.
"""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def cabinet_names(path):
    with path.open('rb') as stream:
        header = stream.read(36)
        if len(header) != 36 or header[:4] != b'MSCF':
            raise ValueError(f'Invalid Microsoft cabinet: {path}')
        stream.seek(struct.unpack_from('<I', header, 16)[0])
        for _ in range(struct.unpack_from('<H', header, 28)[0]):
            if len(stream.read(16)) != 16:
                raise ValueError(f'Truncated file directory: {path}')
            name = bytearray()
            while True:
                char = stream.read(1)
                if not char:
                    raise ValueError(f'Truncated cabinet filename: {path}')
                if char == b'\0':
                    break
                name += char
            yield name.decode('cp1252')


def destination(name):
    upper = name.upper()
    if '/' in name or '\\' in name:
        return None
    if upper.startswith('RESOURCE.'):
        return Path('RESOURCE') / name
    if upper.startswith('DATAACA') and upper.endswith('.000'):
        return Path('DATAA') / name
    if upper == 'RUNAWAY.EXE':
        return Path(name)
    return None


def prepare(source, output):
    source = source.resolve()
    output = output.resolve()
    if not source.is_dir():
        raise ValueError('The source must be a Runaway installation-media folder')
    if output == source or source in output.parents or output in source.parents:
        raise ValueError('Choose a separate output folder outside the installation media')
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError('The output must be a new or empty directory')
    cab_dir = next((p for p in source.iterdir() if p.name.upper() == 'CAB' and p.is_dir()), None)
    if cab_dir is None:
        raise ValueError('The installation-media folder has no Cab directory')
    cabextract = shutil.which('cabextract')
    if not cabextract:
        raise ValueError('Install cabextract, then run this command again')
    output.mkdir(parents=True, exist_ok=True)
    known = set()
    linked = extracted = 0
    for folder in source.iterdir():
        if folder.name.upper() not in {'RESOURCE', 'DATAA'} or not folder.is_dir():
            continue
        for path in folder.iterdir():
            target = destination(path.name)
            if not path.is_file() or target is None:
                continue
            dest = output / target
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(path.resolve())
            known.add(str(target).upper())
            linked += 1
    with tempfile.TemporaryDirectory(prefix='runaway-cabinets-') as temp:
        for cabinet in sorted(cab_dir.iterdir()):
            if cabinet.suffix.lower() != '.cab':
                continue
            for name in cabinet_names(cabinet):
                target = destination(name)
                if target is None or str(target).upper() in known:
                    continue
                print(f'Extracting {cabinet.name}: {name}', flush=True)
                subprocess.run([cabextract, '-q', '-F', name, '-d', temp, str(cabinet)], check=True)
                staged = Path(temp) / name
                if not staged.is_file():
                    raise ValueError(f'cabextract did not produce {name}')
                dest = output / target
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(staged), dest)
                known.add(str(target).upper())
                extracted += 1
    print(f'Ready: {output} ({linked} loose files linked, {extracted} members extracted)')
    print('Keep the original media folder available for the linked loose files.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        prepare(args.source, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
