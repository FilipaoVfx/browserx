# -*- coding: utf-8 -*-
"""Hornea el catalogo de OpenAerialMap dentro de recorrido-terremoto.html.

La API de OAM bloquea CORS (Access-Control-Allow-Origin: https://map.openaerialmap.org)
y responde de forma erratica (se midieron 502 y latencias de hasta 6.6s), asi que el
visualizador no puede consultarla en runtime. Este script la consulta una vez y escribe
el resultado como una constante JS dentro del HTML.

Uso:  python hornear_catalogo.py            # escribe catalogo.json y parchea el HTML
      python hornear_catalogo.py --dry-run  # solo imprime lo que encontro
"""

import base64
import json
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path

# Lado mayor de la miniatura horneada. Las miniaturas viajan como data URI dentro
# del HTML porque en pruebas solo cargaban 3 de 7: compiten con las teselas del mapa
# por el limite de ~6 conexiones por host, y ambas salen del mismo TiTiler.
THUMB_PX = 192

AQUI = Path(__file__).parent
SALIDA_JSON = AQUI / "catalogo.json"
HTML = AQUI / "recorrido-terremoto.html"

MARCA_INICIO = "/* CATALOGO:INICIO */"
MARCA_FIN = "/* CATALOGO:FIN */"

SISMO = "2026-08"  # mes del evento; filtra las tomas post-sismo

# Paradas del recorrido, en orden narrativo: del epicentro hacia donde mas se sintio.
PARADAS = [
    {
        "id": "epicentro",
        "nombre": "San José del Palmar",
        "subtitulo": "Epicentro",
        "depto": "Chocó",
        "bbox": [-76.35, 4.80, -76.10, 5.02],
        "centro": [4.90, -76.23],
        "zoom": 13,
        "relato": "Aquí empezó todo, 5 km al sur, a 110 km de profundidad. "
                  "Es también la zona con menos imagen disponible: el epicentro "
                  "es lo que menos ojos tiene encima.",
    },
    {
        "id": "pereira",
        "nombre": "Pereira",
        "subtitulo": "La más golpeada",
        "depto": "Risaralda",
        "bbox": [-75.85, 4.70, -75.60, 4.92],
        "centro": [4.813, -75.694],
        "zoom": 14,
        "relato": "166 puntos afectados, daños en hospitales y en el aeropuerto Matecaña. "
                  "Es la única zona con imagen antes y después del sismo, así que "
                  "es la única donde se puede comparar directamente.",
    },
    {
        "id": "dosquebradas",
        "nombre": "Dosquebradas",
        "subtitulo": "Conurbada con Pereira",
        "depto": "Risaralda",
        "bbox": [-75.75, 4.80, -75.58, 4.95],
        "centro": [4.845, -75.670],
        "zoom": 14,
        "relato": "Pegada a Pereira y golpeada por la misma onda. La cobertura satelital "
                  "de las dos se solapa: varias tomas cubren ambas a la vez.",
    },
    {
        "id": "manizales",
        "nombre": "Manizales",
        "subtitulo": "Mejor resolución del set",
        "depto": "Caldas",
        "bbox": [-75.62, 4.98, -75.38, 5.15],
        "centro": [5.068, -75.517],
        "zoom": 14,
        "relato": "Ciudad de ladera, donde el sismo se combina con riesgo de deslizamiento. "
                  "Tiene la imagen más detallada de todo el recorrido: 33 cm por píxel.",
    },
    {
        "id": "cali",
        "nombre": "Cali",
        "subtitulo": "La ciudad más grande afectada",
        "depto": "Valle del Cauca",
        "bbox": [-76.65, 3.30, -76.40, 3.58],
        "centro": [3.44, -76.52],
        "zoom": 13,
        "relato": "289 puntos afectados, múltiples estructuras colapsadas y un hospital "
                  "con colapso parcial. Menos imagen de la que su tamaño haría esperar.",
    },
]

# Zonas declaradas afectadas que no tienen NINGUNA imagen post-sismo en OAM.
# Se muestran en la interfaz: la ausencia de dato tambien es dato.
SIN_COBERTURA = [
    {"nombre": "Quibdó", "depto": "Chocó", "centro": [5.69, -76.66]},
    {"nombre": "Armenia", "depto": "Quindío", "centro": [4.53, -75.68]},
]

API = "https://api.openaerialmap.org/meta?bbox={bbox}&limit=100"
TITILER = "https://titiler.hotosm.org/cog"


def pedir(url, intentos=4):
    """GET con reintentos: la API de OAM devuelve 502 de forma intermitente."""
    ultimo = None
    for n in range(intentos):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "recorrido-terremoto/1.0"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001 - queremos reintentar ante cualquier fallo de red
            ultimo = e
            espera = 2 ** n
            print(f"    reintento {n + 1}/{intentos} tras {type(e).__name__} (espera {espera}s)")
            time.sleep(espera)
    raise RuntimeError(f"OAM no respondio tras {intentos} intentos: {ultimo}")


def preview(cog_url, size=256):
    """Miniatura liviana via TiTiler. El thumbnail oficial de OAM pesa ~467KB PNG;
    esto devuelve ~4.8KB JPEG."""
    return f"{TITILER}/preview.jpg?url={cog_url}&max_size={size}"


def bajar_thumb(url_preview):
    """Descarga la miniatura y la devuelve como data URI. Si falla, cadena vacia:
    el visor cae a la URL remota."""
    url = url_preview.replace("max_size=256", f"max_size={THUMB_PX}")
    for n in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "recorrido-terremoto/1.0"})
            with urllib.request.urlopen(req, timeout=120) as r:
                b = r.read()
            if b[:2] != b"\xff\xd8":  # no es JPEG
                return ""
            return "data:image/jpeg;base64," + base64.b64encode(b).decode("ascii")
        except Exception:  # noqa: BLE001
            time.sleep(2 ** n)
    return ""


def zoom_nativo(gsd):
    """Zoom maximo que tiene sentido pedirle a TiTiler segun la resolucion real.
    Mas alla de esto Leaflet escala en cliente en vez de generar tiles nuevos."""
    if not gsd or gsd <= 0:
        return 18
    # ~156543 m/px en z0 en el ecuador; resolvemos z tal que la escala iguale el gsd
    z = 0
    escala = 156543.03
    while escala > gsd and z < 22:
        escala /= 2
        z += 1
    return min(z, 21)


def recolectar(dry_run=False):
    vistas = {}
    paradas_salida = []

    for p in PARADAS:
        bbox = ",".join(str(v) for v in p["bbox"])
        print(f"  {p['nombre']}...")
        try:
            data = pedir(API.format(bbox=bbox))
        except RuntimeError as e:
            print(f"    FALLO: {e}")
            paradas_salida.append({**{k: v for k, v in p.items() if k != "bbox"},
                                   "bbox": p["bbox"], "imagenes": []})
            continue

        ids_parada = []
        for it in data.get("results", []):
            if (it.get("acquisition_end") or "")[:7] != SISMO:
                continue
            _id = it["_id"]
            props = it.get("properties", {})
            cog = props.get("url", "") or ""
            # la URL s3:// no sirve en el navegador; TiTiler usa la variante https
            cog_https = props.get("tilejson", "")
            if "url=" in cog_https:
                cog_https = urllib.parse.unquote(cog_https.split("url=", 1)[1].split("&")[0])
            else:
                cog_https = (it.get("uuid") or "").replace(".png", ".tif")

            titulo = it.get("title", "") or ""
            gsd = round(float(it.get("gsd") or 0), 3)

            if _id not in vistas:
                vistas[_id] = {
                    "id": _id,
                    "titulo": titulo,
                    "fecha": (it.get("acquisition_end") or "")[:10],
                    "gsd": gsd,
                    "zmax": zoom_nativo(gsd),
                    "sensor": props.get("sensor", "") or "",
                    "proveedor": (it.get("provider", "") or "")[:60],
                    "licencia": props.get("license", "") or "",
                    "tms": props.get("tms", "") or "",
                    "preview": preview(cog_https) if cog_https else "",
                    "bbox": [round(v, 6) for v in it.get("bbox", [])],
                    "peso_mb": round((it.get("file_size") or 0) / 1e6),
                    "pre": "PRE" in titulo.upper(),
                    "paradas": [],
                }
            vistas[_id]["paradas"].append(p["id"])
            ids_parada.append(_id)

        print(f"    {len(ids_parada)} imagenes post-sismo")
        paradas_salida.append({
            "id": p["id"], "nombre": p["nombre"], "subtitulo": p["subtitulo"],
            "depto": p["depto"], "centro": p["centro"], "zoom": p["zoom"],
            "relato": p["relato"], "bbox": p["bbox"], "imagenes": ids_parada,
        })

    imagenes = list(vistas.values())

    if not dry_run:
        print(f"\n  Horneando {len(imagenes)} miniaturas a {THUMB_PX}px...")
        for n, img in enumerate(imagenes, 1):
            img["thumb"] = bajar_thumb(img["preview"]) if img["preview"] else ""
            kb = len(img["thumb"]) / 1365 if img["thumb"] else 0  # base64 -> KB reales
            print(f"    {n:>2}/{len(imagenes)} {'ok ' if img['thumb'] else 'FALLO'} "
                  f"{kb:5.1f} KB  {img['titulo'][:38]}")
    else:
        for img in imagenes:
            img["thumb"] = ""

    return {
        "generado": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "thumb_px": THUMB_PX,
        "paradas": paradas_salida,
        "sin_cobertura": SIN_COBERTURA,
        "imagenes": imagenes,
    }


def parchear_html(catalogo):
    if not HTML.exists():
        print(f"  (aun no existe {HTML.name}; solo escribi catalogo.json)")
        return False
    texto = HTML.read_text(encoding="utf-8")
    if MARCA_INICIO not in texto or MARCA_FIN not in texto:
        print(f"  AVISO: no encontre las marcas {MARCA_INICIO} / {MARCA_FIN} en el HTML")
        return False
    antes = texto.split(MARCA_INICIO)[0]
    despues = texto.split(MARCA_FIN)[1]
    bloque = (MARCA_INICIO + "\nconst CATALOGO = "
              + json.dumps(catalogo, ensure_ascii=False, separators=(",", ":"))
              + ";\n" + MARCA_FIN)
    HTML.write_text(antes + bloque + despues, encoding="utf-8")
    return True


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    print("Consultando OpenAerialMap...")
    cat = recolectar(dry)

    n_img = len(cat["imagenes"])
    n_pre = sum(1 for i in cat["imagenes"] if i["pre"])
    print(f"\n{n_img} imagenes unicas | {n_pre} pre-sismo")
    for p in cat["paradas"]:
        print(f"  {p['nombre']:24} {len(p['imagenes'])}")

    if dry:
        sys.exit(0)

    SALIDA_JSON.write_text(json.dumps(cat, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"\nEscrito {SALIDA_JSON.name} ({SALIDA_JSON.stat().st_size / 1024:.0f} KB)")
    if parchear_html(cat):
        print(f"Parcheado {HTML.name}")
