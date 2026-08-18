# -*- coding: utf-8 -*-
"""Ensambla el entregable: plantilla + Leaflet vendorizado + catalogo horneado.

Leaflet se incrusta inline (no por CDN) por la prioridad de disponibilidad:
el archivo no puede romperse porque un CDN de terceros falle.

Uso:  python construir.py
"""

import json
import re
import sys
from pathlib import Path

AQUI = Path(__file__).parent
PLANTILLA = AQUI / "plantilla.html"
CATALOGO = AQUI / "catalogo.json"
LEAFLET_JS = AQUI / "leaflet.js"
LEAFLET_CSS = AQUI / "leaflet.css"
SALIDA = AQUI / "recorrido-terremoto.html"

# Leaflet resuelve las imagenes de marcador por rutas relativas que no existiran
# en un archivo suelto. Usamos solo CircleMarker (vector), asi que las neutralizamos.
IMGS_LEAFLET = re.compile(r"url\((['\"]?)(?!data:)[^)]*?(marker|layers)[^)]*?\1\)")


def falta(p):
    print(f"ERROR: falta {p.name}")
    return True


def main():
    err = False
    for p in (PLANTILLA, CATALOGO, LEAFLET_JS, LEAFLET_CSS):
        if not p.exists():
            err = falta(p)
    if err:
        if not CATALOGO.exists():
            print("  -> corre primero: python hornear_catalogo.py")
        sys.exit(1)

    html = PLANTILLA.read_text(encoding="utf-8")
    cat = json.loads(CATALOGO.read_text(encoding="utf-8"))

    css = LEAFLET_CSS.read_text(encoding="utf-8")
    css = IMGS_LEAFLET.sub("none", css)
    js = LEAFLET_JS.read_text(encoding="utf-8")

    # sourceMappingURL apunta a un archivo que no distribuimos: evita un 404 en consola
    js = re.sub(r"//# sourceMappingURL=\S+\s*$", "", js).strip()

    if "/*LEAFLET_CSS*/" not in html or "/*LEAFLET_JS*/" not in html:
        print("ERROR: la plantilla no tiene los marcadores de Leaflet")
        sys.exit(1)

    html = html.replace("/*LEAFLET_CSS*/", css)
    html = html.replace("/*LEAFLET_JS*/", js)

    ini, fin = "/* CATALOGO:INICIO */", "/* CATALOGO:FIN */"
    if ini not in html or fin not in html:
        print("ERROR: la plantilla no tiene los marcadores de catalogo")
        sys.exit(1)
    bloque = (ini + "\nconst CATALOGO = "
              + json.dumps(cat, ensure_ascii=False, separators=(",", ":"))
              + ";\n" + fin)
    html = html.split(ini)[0] + bloque + html.split(fin)[1]

    SALIDA.write_text(html, encoding="utf-8")

    kb = SALIDA.stat().st_size / 1024
    n_img = len(cat["imagenes"])
    print(f"OK  {SALIDA.name}")
    print(f"    {kb:.0f} KB | {len(cat['paradas'])} paradas | {n_img} imagenes")
    print(f"    Leaflet inline: {(len(css) + len(js)) / 1024:.0f} KB")
    print(f"    catalogo: {len(json.dumps(cat, ensure_ascii=False)) / 1024:.0f} KB")
    import gzip
    gz = len(gzip.compress(html.encode("utf-8"), 9)) / 1024
    print(f"    gzip: {gz:.0f} KB  <- lo que viaja por la red")

    # El presupuesto subio de 260 a 420 KB a proposito: las miniaturas van horneadas
    # como data URI. Sirviendolas desde TiTiler solo cargaban 3 de 7, porque competian
    # con las teselas del mapa por el limite de conexiones al mismo host.
    if kb > 420:
        print("    AVISO: por encima del presupuesto (~420 KB sin comprimir)")


if __name__ == "__main__":
    main()
