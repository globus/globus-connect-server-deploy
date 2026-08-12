#!/usr/bin/env python3
"""
Download an HTTPS URL through a SOCKS5H proxy using only Python 3 stdlib.

Usage: python3 socks5_download.py proxy_host:port url destination

SOCKS5H means the proxy performs DNS resolution on the remote side, matching
the behaviour of curl's --socks5-hostname and apt's socks5h:// scheme.
"""
import http.client
import socket
import ssl
import struct
import sys
import urllib.request


def main():
    proxy, url, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    proxy_host, proxy_port = proxy.rsplit(':', 1)
    proxy_port = int(proxy_port)

    class SOCKS5Connection(http.client.HTTPSConnection):
        """HTTPSConnection that tunnels through a SOCKS5H proxy (remote DNS)."""

        def connect(self):
            # Open a TCP connection to the SOCKS5 proxy
            sock = socket.create_connection((proxy_host, proxy_port))
            # SOCKS5 greeting: version 5, one method offered, no-auth (0x00)
            sock.sendall(b'\x05\x01\x00')
            sock.recv(2)  # server confirms no-auth
            # CONNECT request with FQDN address type (0x03) — proxy resolves the name
            host_b = self.host.encode()
            sock.sendall(
                b'\x05\x01\x00\x03'
                + bytes([len(host_b)])
                + host_b
                + struct.pack('>H', self.port)
            )
            sock.recv(10)  # connection established response
            # Upgrade socket to TLS
            self.sock = ssl.create_default_context().wrap_socket(
                sock, server_hostname=self.host
            )

    class SOCKS5Handler(urllib.request.HTTPSHandler):
        def https_open(self, req):
            return self.do_open(SOCKS5Connection, req)

    # urllib handles HTTP redirects automatically
    opener = urllib.request.build_opener(SOCKS5Handler())
    with opener.open(url) as resp, open(dest, 'wb') as out:
        chunk = resp.read(65536)
        while chunk:
            out.write(chunk)
            chunk = resp.read(65536)


if __name__ == '__main__':
    main()
