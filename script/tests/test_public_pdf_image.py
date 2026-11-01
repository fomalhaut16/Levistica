"""Generated screenshots only; no browser, network, or user files."""
import binascii
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).parents[2]


def png(width=780, height=684, paper=False, ink=False, dialog=False, white_background=False):
    rows = []
    for y in range(height):
        row = bytearray(bytes((255, 255, 255, 255) if white_background else (40, 40, 40, 255)) * width)
        def rectangle(left, right, color):
            row[left * 4:right * 4] = bytes(color) * (right - left)
        if 15 <= y < 25:
            rectangle(60, min(260, width), (255, 255, 255, 255))
        if paper and y >= 70:
            rectangle(70, width - 70, (255, 255, 255, 255))
            if ink and 140 <= y < height - 70 and y % 30 < 8:
                rectangle(140, width - 140, (30, 30, 30, 255))
        if dialog and 200 <= y < 350:
            rectangle(200, 500, (255, 255, 255, 255))
        rows.append(b'\0' + row)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


@unittest.skipUnless(platform.system() == 'Darwin', 'Uses macOS ImageIO and CoreGraphics')
class PublicPDFImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='levistica-pdf-image-')
        cls.folder = Path(cls.temporary.name)
        cls.binary = cls.folder / 'checker'
        env = dict(os.environ)
        if Path('/Applications/Xcode.app/Contents/Developer').exists():
            env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
        result = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', '-module-cache-path', str(cls.folder / 'modules'),
                                 str(ROOT / 'script/check-public-pdf-image.swift'), '-o', str(cls.binary)],
                                env=env, capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError('Image checker compilation failed: ' + result.stderr[-2000:])

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def inspect(self, data):
        file = self.folder / (self.id().split('.')[-1] + '.png')
        file.write_bytes(data)
        result = subprocess.run([str(self.binary), str(file)], capture_output=True, text=True, timeout=10)
        return result.returncode, json.loads(result.stdout)

    def test_viewer_shell_with_small_white_toolbar_text_is_rejected(self):
        code, result = self.inspect(png())
        self.assertEqual(code, 0)
        self.assertFalse(result['paperReady'])

    def test_large_white_paper_and_ink_is_accepted(self):
        code, result = self.inspect(png(paper=True, ink=True))
        self.assertEqual(code, 0)
        self.assertTrue(result['paperReady'])
        self.assertEqual(result['paperWidth'], 640)

    def test_empty_paper_without_ink_is_rejected(self):
        self.assertFalse(self.inspect(png(paper=True))[1]['paperReady'])

    def test_small_white_dialog_is_not_mistaken_for_paper(self):
        self.assertFalse(self.inspect(png(dialog=True))[1]['paperReady'])

    def test_plain_white_background_is_not_paper(self):
        self.assertFalse(self.inspect(png(white_background=True))[1]['paperReady'])

    def test_ineligible_image_size_is_rejected(self):
        code, result = self.inspect(png(width=5000, height=1))
        self.assertEqual(code, 0)
        self.assertFalse(result['paperReady'])

    def test_invalid_image_is_not_accepted_or_echoed(self):
        code, result = self.inspect(b'PRIVATE_SENTINEL')
        self.assertEqual(code, 2)
        self.assertFalse(result['validImage'])
        self.assertNotIn('PRIVATE_SENTINEL', json.dumps(result))

    def test_oversized_file_is_rejected_before_decoding(self):
        file = self.folder / 'oversized.png'
        with file.open('wb') as stream:
            stream.seek(10 * 1024 * 1024)
            stream.write(b'x')
        result = subprocess.run([str(self.binary), str(file)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(result.stdout)['validImage'])


if __name__ == '__main__':
    unittest.main()
