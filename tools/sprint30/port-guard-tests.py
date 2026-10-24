#!/usr/bin/env python3
"""A reusable-listener probe must reject a live listener, yet permit TIME_WAIT."""
import socket


def probe(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        sock.bind(('127.0.0.1',port))
        sock.listen(1)


with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    listener.bind(('127.0.0.1',0))
    listener.listen(1)
    port=listener.getsockname()[1]
    try:
        probe(port)
    except OSError:
        pass
    else:
        raise AssertionError('live listener accepted')
    with socket.create_connection(('127.0.0.1',port),timeout=2) as client:
        with listener.accept()[0] as accepted:
            accepted.shutdown(socket.SHUT_WR)
            assert client.recv(1)==b''
probe(port)
print('S30_PORT_GUARD_LIVE_REFUSAL_AND_CLOSED_REBIND_PASS')
