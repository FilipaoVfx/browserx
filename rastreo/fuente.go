package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Fuente describe de donde se trae el payload de una app del ecosistema.
//
// A proposito NO normaliza: el rastreador solo trae el payload crudo y lo
// deposita. La normalizacion al modelo unificado corre en SQL, junto a los
// indices que deduplican. Asi un cambio de modelo se reprocesa sin volver a
// visitar las fuentes, y el binario no necesita conocer el esquema final.
type Fuente struct {
	ID       string
	Endpoint string
	// Paginas devuelve las URLs a pedir. La mayoria es una sola; sigad exige
	// barrer por celdas porque un bbox demasiado grande para el zoom devuelve
	// cero features SIN error.
	Paginas func() []string
}

const (
	// Identificarse es parte de rastrear con respeto: el operador puede
	// reconocernos en sus logs y bloquearnos si algo va mal.
	userAgent = "browserx-rastreo/0.1 (+https://github.com/FilipaoVfx/browserx)"
	timeout   = 45 * time.Second
	// Pausa entre peticiones a una misma fuente. El corpus es de miles de
	// registros, no millones: no hay razon para apurar a nadie.
	pausa = 1200 * time.Millisecond
)

var fuentes = map[string]Fuente{
	"corag": {
		ID:       "corag",
		Endpoint: "https://ayuda.corag.app/api/public/v1/help",
		Paginas:  paginasCorag,
	},
	"pereiraresponde": {
		ID:       "pereiraresponde",
		Endpoint: "https://pereiraresponde.co/api/reports",
		Paginas: func() []string {
			return []string{"https://pereiraresponde.co/api/reports"}
		},
	},
	"reporteco": {
		ID:       "reporteco",
		Endpoint: "https://co.crafter.run/api/reports.geojson",
		Paginas: func() []string {
			return []string{"https://co.crafter.run/api/reports.geojson"}
		},
	},
	"sigad": {
		ID:       "sigad",
		Endpoint: "https://api.sigad.co/api/v1/map/points/",
		Paginas:  celdasSigad,
	},
}

// paginasCorag parte la consulta por tipo y estado.
//
// La API tope en limit=100 (150 devuelve 400) y NO tiene paginacion: offset,
// page, cursor, skip y from devuelven todos el mismo primer elemento. Con 531
// registros totales, una sola peticion solo alcanza 100.
//
// Partir por tipo x estado sube la cobertura a ~400. El resto es inalcanzable
// hasta que Corag agregue paginacion a su API publica.
func paginasCorag() []string {
	const base = "https://ayuda.corag.app/api/public/v1/help?view=list&limit=100"
	var urls []string
	for _, tipo := range []string{"request", "offer"} {
		for _, estado := range []string{"active", "completed"} {
			urls = append(urls, fmt.Sprintf("%s&type=%s&status=%s", base, tipo, estado))
		}
	}
	return urls
}

// celdasSigad barre la region afectada en celdas de 1 grado.
//
// La API exige coherencia entre bbox y zoom: un bbox nacional con zoom alto
// devuelve cero features y HTTP 200, sin ningun error. Pedir el pais de una vez
// produce un indice vacio que parece exitoso.
func celdasSigad() []string {
	// Barrido acotado al area afectada por el sismo del 10 de agosto: Choco,
	// Valle y Eje Cafetero. Cubrir el pais entero costaba 77 peticiones para
	// obtener datos en 4 celdas; esto baja a 24 sin perder cobertura util.
	const (
		oesteMin, oesteMax = -78.0, -74.0
		surMin, surMax     = 2.0, 8.0
		paso               = 1.0
		zoom               = 10
	)
	var urls []string
	for lon := oesteMin; lon < oesteMax; lon += paso {
		for lat := surMin; lat < surMax; lat += paso {
			urls = append(urls, fmt.Sprintf(
				"https://api.sigad.co/api/v1/map/points/?bbox=%.1f,%.1f,%.1f,%.1f&zoom=%d",
				lon, lat, lon+paso, lat+paso, zoom))
		}
	}
	return urls
}

// Trae pide una URL y devuelve el cuerpo. Reintenta con espera creciente: las
// APIs del ecosistema son proyectos pequenos y devuelven 502 de vez en cuando.
func Trae(ctx context.Context, url string) ([]byte, error) {
	var ultimo error
	for intento := 0; intento < 3; intento++ {
		if intento > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(time.Duration(1<<intento) * time.Second):
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("User-Agent", userAgent)
		req.Header.Set("Accept", "application/json, application/geo+json, */*")

		resp, err := (&http.Client{Timeout: timeout}).Do(req)
		if err != nil {
			ultimo = err
			continue
		}
		cuerpo, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		resp.Body.Close()
		if err != nil {
			ultimo = err
			continue
		}
		if resp.StatusCode != http.StatusOK {
			ultimo = fmt.Errorf("HTTP %d en %s", resp.StatusCode, url)
			// 4xx no se arregla reintentando; 5xx si puede.
			if resp.StatusCode < 500 {
				return nil, ultimo
			}
			continue
		}
		if !json.Valid(cuerpo) {
			return nil, fmt.Errorf("respuesta no es JSON valido en %s", url)
		}
		return cuerpo, nil
	}
	return nil, ultimo
}

// Hash identifica el contenido para no reprocesar lo identico: si la fuente no
// cambio, no se crea fila nueva en crudo.
func Hash(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}
