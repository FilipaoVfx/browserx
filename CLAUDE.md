# Recorrido del desastre — contexto para agentes

Visualizador de imagen satelital abierta del sismo M7.4 del 10 de agosto de 2026 en
Colombia. Un solo archivo HTML autocontenido, sin backend.

## Comandos

```bash
python hornear_catalogo.py    # consulta OpenAerialMap, deduplica, descarga miniaturas
python construir.py           # ensambla plantilla + Leaflet + catalogo -> entregable
python -m http.server 8777    # servir para probar (file:// tambien funciona)
```

No hay tests automatizados. La verificación es manual y está descrita abajo.

## Qué editar y qué no

| Archivo | Editable |
|---|---|
| `plantilla.html` | **Sí.** Es la fuente. Todo el CSS y la lógica viven aquí |
| `hornear_catalogo.py` | **Sí.** Paradas, bboxes, relatos, tamaño de miniatura |
| `construir.py` | **Sí.** Ensamblado |
| `recorrido-terremoto.html` | **No.** Generado. Se sobrescribe en cada build |
| `catalogo.json` | **No.** Generado |
| `leaflet.js`, `leaflet.css` | **No.** Vendorizado, Leaflet 1.9.4 |

Después de tocar `plantilla.html` hay que correr `construir.py`. Editar el HTML
generado directamente es trabajo perdido.

## Restricciones que no se pueden negociar

Estas salieron de mediciones. Cambiarlas rompe cosas que ya se arreglaron.

**No llamar a `api.openaerialmap.org` en runtime.** Bloquea CORS
(`Access-Control-Allow-Origin: https://map.openaerialmap.org`) y respondió 502 con
latencias de hasta 6,6 s. El catálogo va horneado en el HTML.

**No cambiar Leaflet por MapLibre GL.** Las teselas de OAM no traen cabecera CORS.
Leaflet las carga como `<img>` y funciona; MapLibre las sube como textura WebGL y falla.

**No servir las miniaturas desde TiTiler.** Compiten con las teselas del mapa por el
límite de ~6 conexiones al mismo host: solo cargaban 3 de 7. Van como data URI.

**No confiar en que una animación termine.** `flyTo` depende de `requestAnimationFrame`,
que el navegador suspende con la pestaña en segundo plano. Toda función de encuadre pasa
por `encuadrar()`, que fuerza el destino a los 1,5 s si la animación no llegó.

**No mostrar el comparador donde la imagen previa no cubre el centro de la parada.**
La toma pre-sismo mide 34×45 km y cae en el bbox de tres paradas, pero en Manizales solo
roza el borde sur.

## Verificación antes de dar algo por bueno

1. Las 5 paradas aterrizan en su centro y zoom esperados (`__recorrido.map.getCenter()`).
2. Teselas OAM cargan sin fallos (`.oam-tile img.leaflet-tile`, `naturalWidth > 0`).
3. Portada y recorrido muestran el mismo conteo de imágenes por parada.
4. Con TiTiler bloqueado: aviso en pantalla, base y navegación siguen vivas.
5. Con USGS bloqueado: indicador pasa a "datos del 17 ago".
6. Móvil a 375px: sin desborde horizontal y sin solapes entre barra, nav y miniaturas.
7. Peso del entregable por debajo de 420 KB sin comprimir.

En consola hay un handle de diagnóstico: `window.__recorrido = { map, ir, PARADAS, IMGS }`.

## Licencias

La imagen es de OpenAerialMap y **en su mayoría CC BY-NC 4.0**: atribución obligatoria y
**uso no comercial**. Pléiades y la toma pre-sismo son CC-BY 4.0. Cada parada muestra su
licencia y marca las no comerciales. No quitar esa atribución.

## gstack

Instalado con prefijo, los comandos son `/gstack-*`. Útiles aquí:

- `/gstack-design-review` — auditoría visual del recorrido
- `/gstack-qa` — QA en navegador (funciona en esta máquina, verificado)
- `/gstack-review` — revisión antes de landear
- `/gstack-investigate` — depuración con causa raíz

## Skill routing

Cuando la petición encaje con una skill disponible, invócala. Ante la duda, invócala.

- Ideas de producto / brainstorming → /gstack-office-hours
- Estrategia y alcance → /gstack-plan-ceo-review
- Arquitectura → /gstack-plan-eng-review
- Sistema de diseño → /gstack-design-consultation o /gstack-plan-design-review
- Pipeline completo de revisión → /gstack-autoplan
- Bugs y errores → /gstack-investigate
- QA del sitio en navegador → /gstack-qa o /gstack-qa-only
- Revisión de diff → /gstack-review
- Pulido visual → /gstack-design-review
- Ship / deploy / PR → /gstack-ship o /gstack-land-and-deploy
- Guardar progreso → /gstack-context-save
- Retomar contexto → /gstack-context-restore
- Redactar un spec o issue → /gstack-spec
