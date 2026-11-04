"""Test-only HTTPS server bound to 127.0.0.1 (never used by the product).

Usage: python3 https_server.py CERT KEY PORT_FILE ACCESS_LOG

Listens on three 127.0.0.1 ports and writes "TLS_PORT HTTP_PORT PROBE_PORT"
to PORT_FILE once all are listening:
  TLS    the HTTPS server below
  HTTP   plain HTTP: answers any request with 10 bytes
  PROBE  accepts TCP connections and closes them at once
Every accepted TCP connection is logged as "ACCEPT TLS|HTTP|PROBE" to
ACCESS_LOG as soon as it is accepted (before any TLS handshake or request
parsing), and every parsed HTTPS request as "HOST PATH". The HTTPS server
serves:
  /known/N            N bytes with a Content-Length header
  /chunked/N          N bytes, chunked, no Content-Length (N=-1: endless)
  /stall              headers and 5 bytes, then nothing for 60 s
  /short              Content-Length 1000 but closes after 100 bytes
  /redirect/S/K       K more redirects, then /landing/chain-S
  /relative           redirect to the relative path /landing/relative
  /to-http            redirect to http://127.0.0.1:<HTTP port>/landing/http
  /to-host            redirect to https://localhost:<PROBE port>/landing/host
  /to-port            redirect to https://127.0.0.1:<PROBE port>/landing/port
  /loc-empty          redirect with an empty Location
  /loc-userinfo       redirect to https://user:pw@127.0.0.1:<PROBE port>/landing/userinfo
  /loc-port           redirect to https://127.0.0.1:099999/landing/badport
  /loc-ctrl           redirect to the PROBE port, with a control character
  /loc-space          redirect to the PROBE port, with a space
  /landing/NAME       10 bytes
Client disconnects (expected when a download is cut off at its limit) are
not reported; any other server error is.
"""
import http.server
import os
import socket
import ssl
import sys
import threading
import time

CERT, KEY, PORT_FILE, ACCESS_LOG = sys.argv[1:5]
DISCONNECTS = (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError,
               ssl.SSLZeroReturnError)


LOG_LOCK = threading.Lock()


def log_line(line):
    with LOG_LOCK, open(ACCESS_LOG, "a") as log:
        log.write(line + "\n")


def is_disconnect(exc):
    """A client hanging up (as tests do on purpose), not a server error.
    Newer Python/OpenSSL report an EOF as a plain SSLError with this reason."""
    return isinstance(exc, DISCONNECTS) or (
        isinstance(exc, ssl.SSLError)
        and getattr(exc, "reason", None) == "UNEXPECTED_EOF_WHILE_READING")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def setup(self):
        # The TLS handshake is deferred from accept() to here, so that a
        # connection is logged even when the handshake never completes.
        self.request.do_handshake()
        super().setup()

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _body(self, n):
        self.send_response(200)
        self.send_header("Content-Length", str(n))
        self.end_headers()
        self.wfile.write(b"a" * n)

    def do_GET(self):
        log_line("%s %s" % (self.headers.get("Host", "-"), self.path))
        port = self.server.server_address[1]
        base = "https://127.0.0.1:%d" % port
        probe = "127.0.0.1:%d" % PROBE.getsockname()[1]
        parts = self.path.strip("/").split("/")
        try:
            if parts[0] in ("known", "landing"):
                self._body(int(parts[1]) if parts[0] == "known" else 10)
            elif parts[0] == "chunked":
                n = int(parts[1])
                self.send_response(200)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                sent = 0
                while n < 0 or sent < n:
                    size = 4096 if n < 0 else min(4096, n - sent)
                    self.wfile.write(b"%x\r\n" % size + b"a" * size + b"\r\n")
                    sent += size
                self.wfile.write(b"0\r\n\r\n")
            elif parts[0] == "stall":
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                self.wfile.write(b"aaaaa")
                self.wfile.flush()
                time.sleep(60)
            elif parts[0] == "short":
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                self.wfile.write(b"a" * 100)
                self.wfile.flush()
                self.close_connection = True
            elif parts[0] == "redirect":
                start, left = parts[1], int(parts[2])
                self._redirect("%s/redirect/%s/%d" % (base, start, left - 1)
                               if left > 1 else "%s/landing/chain-%s" % (base, start))
            elif parts[0] == "relative":
                self._redirect("/landing/relative")
            elif parts[0] == "to-http":
                self._redirect("http://127.0.0.1:%d/landing/http"
                               % HTTP.server_address[1])
            elif parts[0] == "to-host":
                self._redirect("https://localhost:%d/landing/host"
                               % PROBE.getsockname()[1])
            elif parts[0] == "to-port":
                self._redirect("https://%s/landing/port" % probe)
            elif parts[0] == "loc-empty":
                self._redirect("")
            elif parts[0] == "loc-userinfo":
                self._redirect("https://user:pw@%s/landing/userinfo" % probe)
            elif parts[0] == "loc-port":
                self._redirect("https://127.0.0.1:099999/landing/badport")
            elif parts[0] == "loc-ctrl":
                self._redirect("https://%s/landing/ctrl\x01x" % probe)
            elif parts[0] == "loc-space":
                self._redirect("https://%s/landing/sp ace" % probe)
            else:
                self.send_error(404)
        except DISCONNECTS:
            pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    name = "TLS"

    def get_request(self):
        request = super().get_request()
        log_line("ACCEPT " + self.name)
        return request

    def handle_error(self, request, client_address):
        if not is_disconnect(sys.exc_info()[1]):
            super().handle_error(request, client_address)


class PlainHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "10")
        self.end_headers()
        self.wfile.write(b"a" * 10)


class PlainServer(Server):
    name = "HTTP"


def probe_loop(sock):
    while True:
        conn, _ = sock.accept()
        log_line("ACCEPT PROBE")
        conn.close()


server = Server(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CERT, KEY)
server.socket = context.wrap_socket(server.socket, server_side=True,
                                    do_handshake_on_connect=False)
HTTP = PlainServer(("127.0.0.1", 0), PlainHandler)
PROBE = socket.socket()
PROBE.bind(("127.0.0.1", 0))
PROBE.listen(16)
threading.Thread(target=HTTP.serve_forever, daemon=True).start()
threading.Thread(target=probe_loop, args=(PROBE,), daemon=True).start()
with open(PORT_FILE + ".tmp", "w") as f:
    f.write("%d %d %d" % (server.server_address[1], HTTP.server_address[1],
                          PROBE.getsockname()[1]))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
