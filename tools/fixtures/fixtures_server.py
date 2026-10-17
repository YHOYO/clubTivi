#!/usr/bin/env python3
"""Servidor de fixtures para verificar clubTivi en local.

Sirve los archivos de .dev/fixtures por HTTP y anade rutas especiales para
probar el failover:

  /stall/<cualquiera>   envia un trozo de MPEG-TS y corta (stream colgado)
  /streams/*.mp4        videos de prueba
  /playlist.m3u         playlist M3U Plus
  /epg.xml              guia XMLTV

Uso:  python tools/fixtures/fixtures_server.py [PUERTO]
"""
import functools
import http.server
import os
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
# Las fixtures viven en `.dev/fixtures`, que no se versiona: estos scripts
# estan en `tools/fixtures`, dos carpetas por debajo de la raíz del repo.
_REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOT = os.path.join(_REPO_ROOT, ".dev", "fixtures")

# Bytes de video que se envian antes de estancar el stream.
STALL_BYTES = 60_000


class FixtureHandler(http.server.SimpleHTTPRequestHandler):
    """Handler estatico + endpoint que se queda colgado a proposito."""

    def do_GET(self):  # noqa: N802 (nombre impuesto por la stdlib)
        if self.path.startswith("/stall"):
            # Arranca un MPEG-TS real y deja de enviar datos a mitad: el
            # reproductor llena su buffer, se queda sin entrada y el tiempo
            # de reproduccion se congela (escenario de failover).
            source = os.path.join(ROOT, "streams", "stall_source.ts")
            try:
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                if os.path.exists(source):
                    with open(source, "rb") as fh:
                        self.wfile.write(fh.read(STALL_BYTES))
                    self.wfile.flush()
                # Conexion abierta sin mas datos: el stream se estanca.
                for _ in range(30):
                    time.sleep(1)
            except Exception:
                pass
            return
        super().do_GET()

    def log_message(self, fmt, *args):  # ruido minimo en consola
        sys.stderr.write("[fixtures] %s\n" % (fmt % args))


def main():
    handler = functools.partial(FixtureHandler, directory=ROOT)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler)
    print(f"[fixtures] sirviendo {ROOT} en http://127.0.0.1:{PORT}", flush=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    thread.join()


if __name__ == "__main__":
    main()
