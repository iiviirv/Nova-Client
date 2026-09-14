"""Print the exported symbol names of a PE file (a .dll).

Exists because the obvious tools were both worse. dumpbin is an MSVC tool that
is not on PATH in a plain bash shell on a CI runner, and loading the MSVC
developer environment to reach it reconfigured the toolchain cargo had already
set up correctly, turning a broken check into a broken build.

Standard library only, on purpose: an export check must not be able to disturb
the thing it is checking.

Usage: python tool/pe_exports.py path/to/library.dll
"""
# point is to depend on nothing the build might disagree with.
import struct, sys

def exports(path):
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3C)[0]
    if d[pe:pe + 4] != b'PE\0\0':
        raise SystemExit('not a PE file')
    nsec, = struct.unpack_from('<H', d, pe + 6)
    opt, = struct.unpack_from('<H', d, pe + 20)
    magic, = struct.unpack_from('<H', d, pe + 24)
    # The export directory is the first data directory; where it sits
    # depends on whether this is PE32 or PE32+.
    dd = pe + 24 + (112 if magic == 0x20b else 96)
    rva, _size = struct.unpack_from('<II', d, dd)
    if rva == 0:
        return []
    secs = pe + 24 + opt
    def to_off(r):
        for i in range(nsec):
            s = secs + 40 * i
            va, vsz = struct.unpack_from('<II', d, s + 12)[0], struct.unpack_from('<I', d, s + 8)[0]
            raw = struct.unpack_from('<I', d, s + 20)[0]
            if va <= r < va + max(vsz, 1):
                return raw + (r - va)
        raise SystemExit('rva %#x is outside every section' % r)
    e = to_off(rva)
    n_names, = struct.unpack_from('<I', d, e + 24)
    names_rva, = struct.unpack_from('<I', d, e + 32)
    out = []
    base = to_off(names_rva)
    for i in range(n_names):
        nr, = struct.unpack_from('<I', d, base + 4 * i)
        o = to_off(nr)
        out.append(d[o:d.index(b'\0', o)].decode('ascii', 'replace'))
    return out

for name in exports(sys.argv[1]):
    print(name)
