#!/usr/bin/env python3
"""Loopback-only FFI probe: prove HTTP/2 and fragmentation reach the wire.
Usage: python3 tool/aether_h2_wire_probe.py /path/to/libaether.dylib
Creates a throwaway identity and TLS certificate; never registers with WARP.
"""
import base64
import ctypes
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

lib = ctypes.CDLL(sys.argv[1])
lib.aether_string_free.argtypes = [ctypes.c_void_p]
for name, args in {
    'aether_version': [], 'aether_identity_open': [ctypes.c_char_p],
    'aether_verify_start': [ctypes.c_uint64, ctypes.c_char_p],
    'aether_tunnel_start': [ctypes.c_uint64, ctypes.c_char_p],
    'aether_job_poll': [ctypes.c_uint64], 'aether_job_cancel': [ctypes.c_uint64],
}.items():
    fn = getattr(lib, name)
    fn.argtypes = args
    fn.restype = ctypes.c_void_p

def call(name, *args):
    ptr = getattr(lib, 'aether_' + name)(*args)
    try:
        reply = json.loads(ctypes.string_at(ptr))
    finally:
        lib.aether_string_free(ptr)
    assert reply.get('ok'), reply
    return reply

def payload(value):
    return json.dumps(value).encode()

def finish(job):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        reply = call('job_poll', job)
        if reply['state'] != 'running':
            return reply.get('result', {})
        time.sleep(.01)
    raise AssertionError('native work survived cancellation')

assert call('version').get('nova_h2_fragment') == 1, 'unpatched core'
with tempfile.TemporaryDirectory(prefix='nova-h2-wire-') as work:
    work = Path(work)
    subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt',
                    'ec_paramgen_curve:prime256v1','-nodes','-days','2',
                    '-subj','/CN=loopback.invalid','-keyout',str(work/'key.pem'),
                    '-out',str(work/'cert.pem')],check=True,capture_output=True)
    identity = dict(device_id='loopback-test', access_token='not-a-real-token',
                    cert_pem=(work/'cert.pem').read_text(), key_pem=(work/'key.pem').read_text(),
                    cert_issued_at=int(time.time()), ipv4='172.16.0.2', ipv6='::1',
                    wg_private_key=base64.b64encode(bytes([7])*32).decode(),
                    wg_peer_public_key=base64.b64encode(bytes([9])*32).decode())
    (work/'identity-masque.toml').write_text(''.join(f'{k} = {json.dumps(v)}\n' for k,v in identity.items()))
    opened = call('identity_open',payload({'path':str(work/'identity.toml'),'transport':'h2'}))
    result = finish(opened['job'])
    assert result.get('ok'), result
    handle = result['identity']
    for operation in ['verify_start','tunnel_start']:
        for fragmented in [True,False]:
            with socket.socket() as server:
                server.bind(('127.0.0.1',0));server.listen();server.settimeout(4)
                with socket.socket() as scratch:
                    scratch.bind(('127.0.0.1',0));socks_port=scratch.getsockname()[1]
                job = call(operation,handle,payload(dict(peer=f'127.0.0.1:{server.getsockname()[1]}',
                    socks=f'127.0.0.1:{socks_port}',transport='h2',fragment=fragmented,
                    fragment_size='16',fragment_delay='50')))['job']
                try:
                    with server.accept()[0] as conn:
                        conn.settimeout(3)
                        first=conn.recv(65535)
                        assert first and first[0] == 22, 'expected a TLS ClientHello record'
                        if fragmented:
                            assert len(first)<=16, len(first)
                            start=time.monotonic();second=conn.recv(65535)
                            assert 0<len(second)<=16,len(second)
                            assert time.monotonic()-start>=.03,'fragment delay was not applied'
                        else:
                            assert len(first)>32, 'disabled fragmentation still splits the hello'
                finally:
                    call('job_cancel',job);finish(job)
                print(operation, 'fragmented' if fragmented else 'plain', 'TCP/TLS verified')
print('PASS: HTTP2 uses TCP; custom fragment size/delay and cancellation reach the native wire path.')
