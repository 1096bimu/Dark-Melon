#!/usr/bin/env python3
"""Extract the first JPEG codestream without HDR metadata or recompressing pixels."""
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
assert data[:2] == b'\xff\xd8', 'Not a JPEG'
out = bytearray(data[:2])
i = 2
while i < len(data):
    assert data[i] == 255
    start = i
    while data[i] == 255:
        i += 1
    marker = data[i]
    i += 1
    if marker == 0xD9:
        out += data[start:i]
        break
    length = int.from_bytes(data[i:i+2], 'big')
    end = i + length
    payload = data[i+2:end]
    # Retain the color profile, but no MPF, ISO gain-map, EXIF or vendor metadata.
    if marker == 0xE0 and payload.startswith(b'JFIF\0'):
        payload = payload[:14]  # no embedded thumbnail or Apple MPF extension
        payload = payload[:12] + b'\0\0'
        out += b'\xff\xe0' + (len(payload)+2).to_bytes(2, 'big') + payload
    elif not 0xE0 <= marker <= 0xEF or (marker == 0xE2 and payload.startswith(b'ICC_PROFILE\0')):
        out += data[start:end]
    i = end
    if marker == 0xDA:
        start = i
        while True:
            i = data.index(b'\xff', i)
            j = i + 1
            while data[j] == 255:
                j += 1
            if data[j] == 0 or 0xD0 <= data[j] <= 0xD7:
                i = j + 1
                continue
            out += data[start:i]
            break
else:
    raise ValueError('Missing JPEG end marker')
destination.write_bytes(out)
print(f'{destination}: {len(out)} bytes; original compressed pixels and ICC profile retained')
