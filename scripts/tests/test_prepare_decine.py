import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare_decine', Path(__file__).parents[1] / 'prepare-decine.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def cabinet(name):
    header = bytearray(36)
    header[:4] = b'MSCF'
    struct.pack_into('<I', header, 16, 36)
    struct.pack_into('<H', header, 28, 1)
    return header + bytes(16) + name + b'\0'


class PreparationTests(unittest.TestCase):
    def test_spanish_names(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'data.cab'
            p.write_bytes(cabinet('Animaciones/DRÁCULA.AN0'.encode('cp1252')))
            self.assertEqual(list(module.members(p)), [Path('Animaciones/DRÁCULA.AN0')])

    def test_unsafe_and_truncated_cabinets(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'data.cab'
            for name in (b'../outside', b'/absolute', b'C:\\outside', b'Folder/../../outside'):
                p.write_bytes(cabinet(name))
                with self.assertRaises(ValueError):
                    list(module.members(p))
            p.write_bytes(cabinet(b'file')[:-1])
            with self.assertRaises(ValueError):
                list(module.members(p))

    def test_preserves_existing_data(self):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp) / 'source', Path(temp) / 'output'
            source.mkdir()
            output.mkdir()
            sentinel = output / 'keep'
            sentinel.write_text('untouched')
            for dest in (source, source / 'nested', output):
                with self.assertRaises(ValueError):
                    module.prepare(source, dest)
            self.assertEqual(sentinel.read_text(), 'untouched')


if __name__ == '__main__':
    unittest.main()
