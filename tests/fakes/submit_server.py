"""Test-only stand-in for the TariTalk Nodes submission service, bound to
127.0.0.1 over TLS (never used by the product).

Usage: python3 submit_server.py CERT KEY PORT_FILE ACCESS_LOG

Writes its port to PORT_FILE once it listens. Logs to ACCESS_LOG:
  ACCEPT                   a TCP connection was accepted (before TLS)
  REQUEST METHOD PATH      a request line and its headers were parsed
  BODY <bytes>             the request body, once read in full
The path decides the answer to a POST (anything else is 405):
  /submit     200 {"ok":true,"submission_id":"sub_test0001","status":"pending"}
  /reject     400 {"ok":false,"error":"invalid_field","field":"public_ip"}
  /limited    429 {"ok":false,"error":"rate_limited"}
  /error      500 {"ok":false,"error":"storage_error"}
  /garbage    200 with a body that is not the service's answer
  /drop       reads the body, then closes the connection without answering
  /stall      reads the body, then never answers (60 s)
"""
import http.server
import os
import ssl
import sys
import threading
import time

CERT, KEY, PORT_FILE, ACCESS_LOG = sys.argv[1:5]
LOG_LOCK = threading.Lock()


def log_line(line):
    with LOG_LOCK, open(ACCESS_LOG, "a") as log:
        log.write(line + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def setup(self):
        self.request.do_handshake()
        super().setup()

    def _json(self, code, text):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        log_line("REQUEST GET %s" % self.path)
        self._json(405, '{"ok":false,"error":"method_not_allowed"}')

    def do_POST(self):
        log_line("REQUEST POST %s" % self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        log_line("BODY " + body.decode("utf-8", "replace"))
        path = self.path
        try:
            if path == "/submit":
                self._json(200, '{"ok":true,"submission_id":"sub_test0001","status":"pending"}')
            elif path == "/reject":
                self._json(400, '{"ok":false,"error":"invalid_field","field":"public_ip"}')
            elif path == "/limited":
                self._json(429, '{"ok":false,"error":"rate_limited"}')
            elif path == "/error":
                self._json(500, '{"ok":false,"error":"storage_error"}')
            elif path == "/garbage":
                self._json(200, "<html>not the service</html>")
            elif path == "/drop":
                self.close_connection = True
                self.connection.close()
            elif path == "/stall":
                time.sleep(60)
            else:
                self._json(404, '{"ok":false,"error":"not_found"}')
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def get_request(self):
        request = super().get_request()
        log_line("ACCEPT")
        return request

    def handle_error(self, request, client_address):
        # Clients hanging up (or failing the TLS handshake) are expected.
        pass


server = Server(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CERT, KEY)
server.socket = context.wrap_socket(server.socket, server_side=True,
                                    do_handshake_on_connect=False)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write("%d" % server.server_address[1])
os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
