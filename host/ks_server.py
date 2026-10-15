# ==============================================================================
# Tytul:        ks_server.py
# Opis:         Lekki serwer HTTP (Python stdlib) serwujacy WYLACZNIE katalogi
#               kickstart/ i guest/ z repo do VMek podczas instalacji. Raw socket,
#               wiec NIE dotyka http.sys -- brak URL ACL, brak osieroconych portow,
#               brak exclusion. Whitelista chroni reszte repo (np. lab.config.psd1).
# Description [EN]: Lightweight HTTP server (Python stdlib) serving ONLY the
#               kickstart/ and guest/ directories to VMs during install. Raw socket
#               -> does NOT touch http.sys (no URL ACL / orphaned ports / exclusion).
#               The allowlist protects the rest of the repo (e.g. lab.config.psd1).
#
# Autor:        KCB Kris
# Data:         2026-05-30
# Wersja:       1.0
# <repo>:       <repo>
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Python 3.8+ (http.server ze stdlib)
# Requirements [EN]: - Python 3.8+ (http.server from stdlib)
#
# Uzycie [PL]:       python ks_server.py <repo_root> <bind_ip> <port>
# Usage [EN]:        python ks_server.py <repo_root> <bind_ip> <port>
# ==============================================================================

import os
import sys
import http.server
import socketserver
import urllib.parse

# --- Argumenty / args --------------------------------------------------------
if len(sys.argv) != 4:
    sys.stderr.write("usage: ks_server.py <repo_root> <bind_ip> <port>\n")
    sys.exit(2)

REPO_ROOT = os.path.abspath(sys.argv[1])
BIND_IP = sys.argv[2]
PORT = int(sys.argv[3])

# Whitelista katalogow serwowanych do VMek / allowed served directories
ALLOWED_DIRS = [
    os.path.abspath(os.path.join(REPO_ROOT, "kickstart")),
    os.path.abspath(os.path.join(REPO_ROOT, "guest")),
]

# Rozszerzenia serwowane jako text/plain / served as text/plain
TEXT_EXT = {
    ".sh", ".ks", ".tmpl", ".conf", ".cfg", ".ini",
    ".yml", ".yaml", ".txt", ".service",
}


def _is_allowed(candidate):
    """Czy sciezka lezy wewnatrz dozwolonych katalogow (anty-traversal)."""
    for base in ALLOWED_DIRS:
        if candidate == base or candidate.startswith(base + os.sep):
            return True
    return False


class KsHandler(http.server.BaseHTTPRequestHandler):
    server_version = "pgio-ks-server/1.0"

    def _serve(self, write_body):
        rel = urllib.parse.unquote(self.path.split("?", 1)[0]).lstrip("/")
        candidate = os.path.abspath(os.path.join(REPO_ROOT, rel))

        if _is_allowed(candidate) and os.path.isfile(candidate):
            with open(candidate, "rb") as fh:
                data = fh.read()
            ext = os.path.splitext(candidate)[1].lower()
            ctype = "text/plain; charset=utf-8" if ext in TEXT_EXT else "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if write_body:
                self.wfile.write(data)
        else:
            msg = ("404 Not Found: %s\n" % rel).encode("utf-8")
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            if write_body:
                self.wfile.write(msg)

    def do_GET(self):
        self._serve(write_body=True)

    def do_HEAD(self):
        self._serve(write_body=False)

    def log_message(self, fmt, *args):
        # Access log -> STDERR (tak jak python -m http.server)
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    httpd = ThreadingHTTPServer((BIND_IP, PORT), KsHandler)
    sys.stderr.write(
        "pgio-ks-server: serving kickstart/ + guest/ from %s on http://%s:%d/\n"
        % (REPO_ROOT, BIND_IP, PORT)
    )
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
