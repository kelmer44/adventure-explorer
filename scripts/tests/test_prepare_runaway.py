"""Run: python3 -m unittest discover -s scripts/tests -p 'test_prepare_runaway.py'."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_runaway', Path(__file__).parents[1] / 'prepare-runaway.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PreparationTests(unittest.TestCase):
    def test_cabinet_directory(self):
        header = bytearray(36)
        header[:4] = b'MSCF'
        struct.pack_into('<I', header, 16, 36)
        struct.pack_into('<H', header, 28, 2)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'data.cab'
            path.write_bytes(header + bytes(16) + b'Resource.000\0' + bytes(16) + b'DATAACA0.000\0')
            self.assertEqual(list(prepare.cabinet_names(path)), ['Resource.000', 'DATAACA0.000'])
            path.write_bytes(header + bytes(16) + b'truncated')
            with self.assertRaises(ValueError):
                list(prepare.cabinet_names(path))

    def test_only_expected_members(self):
        self.assertEqual(prepare.destination('Resource.A01'), Path('RESOURCE/Resource.A01'))
        self.assertEqual(prepare.destination('DATAACA0.000'), Path('DATAA/DATAACA0.000'))
        self.assertEqual(prepare.destination('Runaway.exe'), Path('Runaway.exe'))
        for name in ('../RESOURCE.A01', 'Xtras\\RESOURCE.A01', '/RESOURCE.A01', 'DATAVA01.001', 'binkw32.dll'):
            self.assertIsNone(prepare.destination(name))

    def test_source_and_existing_output_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'media'
            (source / 'Cab').mkdir(parents=True)
            existing = Path(temp) / 'existing'
            existing.mkdir()
            (existing / 'keep').write_text('original')
            for output in (source, source / 'nested', Path(temp), existing):
                with self.assertRaises(ValueError):
                    prepare.prepare(source, output)
            self.assertEqual((existing / 'keep').read_text(), 'original')
            self.assertFalse((source / 'nested').exists())

    def test_missing_inputs_do_not_create_output(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'media'
            source.mkdir()
            output = Path(temp) / 'output'
            with self.assertRaises(ValueError):
                prepare.prepare(source, output)
            self.assertFalse(output.exists())
            (source / 'Cab').mkdir()
            with patch.object(prepare.shutil, 'which', return_value=None), self.assertRaises(ValueError):
                prepare.prepare(source, output)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
