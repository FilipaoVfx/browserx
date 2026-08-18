# Recorrido del desastre — Colombia, 10 de agosto de 2026

Recorrido guiado por imagen satelital abierta de las zonas afectadas por el sismo M7.4.
Un solo archivo HTML, sin backend y sin dependencias externas de JavaScript.

## Entregable

**`recorrido-terremoto.html`** — 375 KB (190 KB por la red con gzip). Autocontenido:
ábrelo con doble clic o súbelo a cualquier hosting estático sin tocar nada.

## Cómo regenerar

```bash
python hornear_catalogo.py   # consulta OpenAerialMap y hornea catálogo + miniaturas
python construir.py          # ensambla plantilla + Leaflet + catálogo
```

| Archivo | Rol |
|---|---|
| `recorrido-terremoto.html` | El entregable |
| `plantilla.html` | Fuente editable (marcadores `/*LEAFLET_JS*/`, `CATALOGO:INICIO`) |
| `hornear_catalogo.py` | Consulta OAM, deduplica, descarga miniaturas |
| `construir.py` | Ensambla el archivo final |
| `catalogo.json` | Catálogo horneado (187 KB, incluye miniaturas en base64) |
| `leaflet.js` / `leaflet.css` | Leaflet 1.9.4, se incrusta inline |

## Por qué está construido así

Cada decisión salió de una medición, no de una preferencia.

**El catálogo va horneado, no se consulta en vivo.**
La API de OAM bloquea CORS (`Access-Control-Allow-Origin: https://map.openaerialmap.org`),
así que el navegador no puede llamarla. Además respondió 502 durante el desarrollo y con
latencias de 1,4 a 6,6 s. La página no puede depender de ese servicio.

**Leaflet, no MapLibre GL.**
Las teselas de OAM no traen cabecera CORS. Leaflet las carga como `<img>` y funciona;
MapLibre necesita CORS para subirlas como textura WebGL y fallaría.

**Las miniaturas viajan como data URI dentro del HTML.**
Sirviéndolas desde TiTiler solo cargaban 3 de 7: compiten con las teselas del mapa por el
límite de ~6 conexiones por host, y ambas salen del mismo servidor. Horneadas a 192 px
pesan 129 KB, cargan siempre y sobreviven a que TiTiler se caiga. El thumbnail oficial de
OAM pesa 467 KB en PNG; el `preview.jpg` de TiTiler, 4,8 KB.

**Paradas fijas, no exploración libre.**
Las teselas se generan bajo demanda con TiTiler (0,9–1,4 s cada una) pero CloudFront las
cachea una hora. Con paradas fijas todos los usuarios piden el mismo conjunto: el usuario
100 le pega a la caché, no al servidor. La exploración libre haría lo contrario.

**El encuadre tiene red de seguridad.**
`flyTo` depende de `requestAnimationFrame`, que el navegador suspende con la pestaña en
segundo plano: la animación nunca avanza y el mapa se queda en la parada anterior. Si a
1,5 s no llegó al destino, se fuerza sin animar. El encuadre es corrección, no decoración.

**La imagen "antes" solo cuenta donde de verdad cubre.**
La toma pre-sismo de Pereira mide 34×45 km y cae dentro del bbox de tres paradas, pero en
Manizales solo roza el borde sur. El comparador aparece únicamente donde la imagen cubre el
punto de la parada: comparar bordes engaña.

**El apilado prioriza cobertura sobre nitidez.**
El bbox de cada COG envuelve una huella rotada, así que hay zonas sin dato que TiTiler
devuelve en negro (las teselas son JPEG, sin transparencia). Arriba va la imagen que cubre
el centro de la parada; a igualdad, la más nítida.

## Degradación (probada, no supuesta)

| Falla simulada | Resultado medido |
|---|---|
| TiTiler caído | 94 teselas fallan, 94 reintentos, aviso en pantalla. Base, miniaturas y navegación siguen vivas |
| USGS caído | Cae al registro guardado, el indicador pasa a "datos del 17 ago", aviso en pantalla |
| API de OAM caída | Sin efecto: no se consulta en runtime |

## Cobertura

| Parada | Imágenes | Nota |
|---|---|---|
| San José del Palmar | 1 | Epicentro |
| Pereira | 7 | Única con antes/después |
| Dosquebradas | 7 | Solapa con Pereira |
| Manizales | 7 | Mejor resolución: 0,33 m/px |
| Cali | 3 | |

**Quibdó y Armenia: 0 imágenes.** Aparecen vacías a propósito — la ausencia de dato también
es dato.

## Licencias

Imagen de OpenAerialMap (HOTOSM). La mayoría es **CC BY-NC 4.0** (Vantor): atribución
obligatoria y **uso no comercial**. Las de Pléiades y la toma pre-sismo son CC-BY 4.0.
Cada parada muestra su licencia y marca las no comerciales.

Sismos: USGS. Mapa base: CARTO y OpenStreetMap.

## Diagnóstico

En consola: `window.__recorrido` expone `{ map, ir, PARADAS, IMGS }`.

```js
__recorrido.ir(3)                    // saltar a Manizales
__recorrido.map.getCenter()          // verificar encuadre
```
