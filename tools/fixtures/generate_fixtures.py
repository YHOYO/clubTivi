#!/usr/bin/env python3
"""Genera fixtures locales para verificar clubTivi sin usar un proveedor IPTV real.

Crea:
  .dev/fixtures/streams/*.mp4   videos de prueba (generados con ffmpeg, sin copyright)
  .dev/fixtures/playlist.m3u    playlist M3U Plus con tvg-id/tvg-name/group-title
  .dev/fixtures/epg.xml         guia XMLTV con programas centrados en "ahora"

Uso:  python tools/fixtures/generate_fixtures.py [PUERTO]
Luego: python tools/fixtures/fixtures_server.py PUERTO
"""
import gzip
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
import datetime as dt

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
# Las fixtures se generan en `.dev/fixtures`, que no se versiona: estos scripts
# viven en `tools/fixtures`, dos carpetas por debajo de la raíz del repo.
_REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOT = os.path.join(_REPO_ROOT, ".dev", "fixtures")
STREAMS = os.path.join(ROOT, "streams")
os.makedirs(STREAMS, exist_ok=True)

# (archivo, etiqueta, frecuencia del tono)
VIDEOS = [
    ("stream_a.mp4", "CT News", 440),
    ("stream_b.mp4", "CT Sports", 880),
    ("stream_c.mp4", "CT Movies", 660),
]

# (tvg_id, nombre en la playlist, grupo, archivo, tipo)
# Algunas entradas no llevan tvg-id o llevan prefijo de pais a proposito: asi se
# ejercitan los niveles heuristicos del auto-mapper y no solo el match exacto.
CHANNELS = [
    ("ct.test.news", "CT Test News", "Noticias", "stream_a.mp4", "live"),
    (None, "US| CT Test News 24", "Noticias", "stream_b.mp4", "live"),
    ("ct.test.sports", "CT Test Sports", "Deportes", "stream_b.mp4", "live"),
    (None, "CT Test Sports Extra", "Deportes", "stream_c.mp4", "live"),
    (None, "CT Test Movies", "Peliculas", "stream_c.mp4", "vod"),
    ("ct.test.radio", "CT Test Radio", "Radio", "stream_a.mp4", "live"),
]

# Canales de la guia EPG (display-name tal como lo publica el proveedor)
EPG_CHANNELS = [
    ("ct.test.news", "CT Test News"),
    ("ct.test.news2", "CT Test News 24"),
    ("ct.test.sports", "CT Test Sports"),
    ("ct.test.sports2", "CT Test Sports Extra"),
    ("ct.test.movies", "CT Test Movies"),
    ("ct.test.radio", "CT Test Radio"),
]


def ffmpeg_available():
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        return True
    except Exception:
        return False


LARGE_CHANNELS = 600
LARGE_PROGRAMMES_PER_CHANNEL = 300  # 600 x 300 = 180 000 programas

def generate_videos():
    if not ffmpeg_available():
        raise SystemExit("ffmpeg no esta disponible en PATH")
    for name, label, freq in VIDEOS:
        path = os.path.join(STREAMS, name)
        if os.path.exists(path) and os.path.getsize(path) > 0:
            print(f"  ya existe {name}")
            continue
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=640x360:rate=25:duration=30",
            "-f", "lavfi", "-i", f"sine=frequency={freq}:duration=30",
            "-vf", f"drawtext=text='{label}':fontsize=40:x=20:y=20:fontcolor=white,"
                   "format=yuv420p",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "30",
            "-c:a", "aac", "-b:a", "64k", "-shortest",
            # moov al principio: asi mpv conoce la duracion al abrir por HTTP
            "-movflags", "+faststart",
            path,
        ]
        subprocess.run(cmd, check=True)
        print(f"  generado {name} ({os.path.getsize(path)} bytes)")


def generate_stall_stream():
    """MPEG-TS valido para /stall: se sirve un trozo y luego se corta."""
    src = os.path.join(STREAMS, "stream_a.mp4")
    dst = os.path.join(STREAMS, "stall_source.ts")
    if not os.path.exists(src):
        return
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        print(f"  ya existe {os.path.basename(dst)}")
        return
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", src, "-c", "copy", "-f", "mpegts", dst,
    ]
    subprocess.run(cmd, check=True)
    print(f"  generado {os.path.basename(dst)} ({os.path.getsize(dst)} bytes)")




def _xmltv_ts(moment):
    """Marca de tiempo XMLTV: 20260114203000 +0000."""
    return moment.strftime("%Y%m%d%H%M%S %z")


def write_large_epg():
    """EPG grande y realista para medir la memoria del refresco.

    600 canales x 300 programas de 15 minutos = 180 000 programas, que es el
    orden de magnitud de un feed publico completo.
    """
    path = os.path.join(ROOT, "epg-large.xml.gz")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        print(f"  ya existe {os.path.basename(path)}")
        return

    # Empieza dos horas atras: todo debe caer dentro de la ventana que
    # conserva el servicio (1 dia atras, 7 dias adelante).
    start = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    start -= timedelta(hours=2)
    step = timedelta(minutes=15)

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<tv generator-info-name="clubTivi fixtures">',
    ]
    for index in range(LARGE_CHANNELS):
        lines.append(f'<channel id="large.{index}.tv">'
                     f'<display-name>Large {index}</display-name></channel>')
    for index in range(LARGE_CHANNELS):
        slot = start
        for number in range(LARGE_PROGRAMMES_PER_CHANNEL):
            stop = slot + step
            lines.append(
                f'<programme start="{_xmltv_ts(slot)}" stop="{_xmltv_ts(stop)}" '
                f'channel="large.{index}.tv">'
                f'<title>Large {index} show {number}</title>'
                f'<desc>Programa de prueba {number} del canal {index} usado para '
                f'medir el consumo de memoria del refresco de EPG.</desc>'
                f'<category>Series</category></programme>'
            )
            slot = stop
    lines.append('</tv>')

    raw = "\n".join(lines).encode("utf-8")
    with gzip.open(path, "wb") as fh:
        fh.write(raw)
    print(f"  generado {os.path.basename(path)} ({os.path.getsize(path)} bytes, "
          f"{LARGE_CHANNELS * LARGE_PROGRAMMES_PER_CHANNEL} programas, "
          f"xml {len(raw)} bytes)")


def write_playlist():
    lines = ["#EXTM3U"]
    for index, (tvg_id, name, group, stream, kind) in enumerate(CHANNELS, start=1):
        url = f"http://127.0.0.1:{PORT}/streams/{stream}"
        id_attr = f'tvg-id="{tvg_id}" ' if tvg_id else ""
        lines.append(
            f'#EXTINF:-1 {id_attr}tvg-name="{name}" '
            f'tvg-chno="{index}" tvg-logo="http://127.0.0.1:{PORT}/logo.png" '
            f'group-title="{group}",{name}'
        )
        lines.append(url)
    # Un canal "roto" a proposito: sirve para que un canal alternativo pueda
    # respaldarlo en las pruebas de failover (el puerto 9 descarta conexiones).
    lines.insert(1, '#EXTINF:-1 tvg-id="ct.test.dead" tvg-name="CT Dead Stream" '
                    'tvg-chno="0" group-title="Noticias",CT Dead Stream')
    lines.insert(2, "http://127.0.0.1:9/dead/stream.m3u8")
    with open(os.path.join(ROOT, "playlist.m3u"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"  playlist.m3u con {len(CHANNELS) + 1} canales")


def xmltv_time(moment):
    return moment.strftime("%Y%m%d%H%M%S +0000")


def write_epg():
    now = dt.datetime.now(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<tv generator-info-name="clubtivi-local-fixtures">']
    for tvg_id, name in EPG_CHANNELS:
        out.append(f'  <channel id="{tvg_id}">')
        out.append(f'    <display-name>{name}</display-name>')
        out.append(f'    <icon src="http://127.0.0.1:{PORT}/logo.png"/>')
        out.append('  </channel>')
    for tvg_id, name in EPG_CHANNELS:
        for offset in (-1, 0, 1, 2):
            start = now + dt.timedelta(hours=offset)
            stop = start + dt.timedelta(hours=1)
            title = f"{name} - Programa {offset + 2}"
            out.append(
                f'  <programme start="{xmltv_time(start)}" stop="{xmltv_time(stop)}" '
                f'channel="{tvg_id}">'
            )
            out.append(f'    <title lang="es">{title}</title>')
            out.append(f'    <desc lang="es">Bloque de prueba {title} '
                       "generado localmente para verificar la guia EPG.</desc>")
            out.append('    <category>Pruebas</category>')
            out.append('  </programme>')
    out.append('</tv>')
    with open(os.path.join(ROOT, "epg.xml"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"  epg.xml con {len(EPG_CHANNELS)} canales y {len(EPG_CHANNELS) * 4} programas")


if __name__ == "__main__":
    print(f"Fixtures en {ROOT} (puerto {PORT})")
    generate_videos()
    generate_stall_stream()
    write_large_epg()
    write_playlist()
    write_epg()
    print("Listo. Sirve con:")
    print(f"  python tools/fixtures/fixtures_server.py {PORT}")
