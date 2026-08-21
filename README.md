# browserx

Visualizador de imagen satelital abierta del sismo M7.4 del 10 de agosto de 2026 en
Colombia. Recorrido guiado por cinco zonas afectadas, en un solo archivo HTML
autocontenido: 375 KB en disco, 190 KB por la red.

**[recorrido-terremoto.html](recorrido-terremoto.html)** — descárgalo y ábrelo, o
sírvelo desde cualquier hosting estático. Sin backend, sin dependencias externas de
JavaScript.

## Qué muestra

| Parada | Imágenes | Nota |
|---|---|---|
| San José del Palmar | 1 | Epicentro |
| Pereira | 7 | Única con antes/después |
| Dosquebradas | 7 | Solapa con Pereira |
| Manizales | 7 | Mejor resolución: 0,33 m/px |
| Cali | 3 | |

Quibdó y Armenia aparecen vacías a propósito: están en los reportes de afectación pero
no tienen ninguna imagen publicada. La ausencia de dato también es dato.

## Construir

```bash
python hornear_catalogo.py   # consulta OpenAerialMap, deduplica, descarga miniaturas
python construir.py          # ensambla plantilla + Leaflet + catálogo
```

## Por qué está construido así

Cada decisión salió de una medición. El detalle completo está en [LEEME.md](LEEME.md)
y las restricciones para agentes en [CLAUDE.md](CLAUDE.md).

- **El catálogo va horneado.** La API de OpenAerialMap bloquea CORS y respondió 502 con
  latencias de hasta 6,6 s durante el desarrollo.
- **Leaflet, no MapLibre GL.** Las teselas no traen cabecera CORS: Leaflet las carga como
  `<img>`, MapLibre las necesita como textura WebGL.
- **Miniaturas como data URI.** Servidas desde TiTiler solo cargaban 3 de 7: competían con
  las teselas del mapa por el límite de conexiones al mismo host.
- **Paradas fijas.** Las teselas se generan bajo demanda pero CloudFront las cachea una
  hora; con paradas fijas todos los usuarios piden el mismo conjunto.

Degradación verificada, no supuesta: con el servidor de teselas caído fallan 94 teselas,
se reintentan y se avisa en pantalla — el mapa base, las miniaturas y la navegación
siguen vivos.

## Licencias

Imagen de [OpenAerialMap](https://openaerialmap.org) (HOTOSM). La mayoría es
**CC BY-NC 4.0** (Vantor): atribución obligatoria y **uso no comercial**. Las de Pléiades
y la toma previa al sismo son CC-BY 4.0. Cada parada muestra su licencia en pantalla.

Sismos: [USGS](https://earthquake.usgs.gov). Mapa base: CARTO y OpenStreetMap.

El código es MIT. La imagen satelital conserva su licencia original.
