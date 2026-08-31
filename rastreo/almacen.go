package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

// Almacen escribe en Supabase via PostgREST.
//
// Usa una secret key (sb_secret_...), no la service_role legacy. La legacy esta
// acoplada a la clave anon: rotar una obliga a rotar la otra y romperia el SPA.
// La secret key se rota sola, devuelve 401 si alguien la usa desde un navegador,
// y admite una por servicio, asi que una fuga no compromete todo.
//
// Salta RLS igual, asi que NUNCA va al repositorio: vive como secret de GitHub
// Actions y se lee del entorno. Es tambien la razon por la que `crudo` tiene RLS
// sin ninguna politica: el payload sin normalizar trae nombres y telefonos que
// el indice publico nunca debe ver.
type Almacen struct {
	url   string
	clave string
	http  *http.Client
}

func NuevoAlmacen() (*Almacen, error) {
	url := strings.TrimSuffix(os.Getenv("SUPABASE_URL"), "/")
	clave := os.Getenv("SUPABASE_SECRET_KEY")
	if url == "" || clave == "" {
		return nil, fmt.Errorf("faltan SUPABASE_URL o SUPABASE_SECRET_KEY en el entorno")
	}
	return &Almacen{url: url, clave: clave, http: &http.Client{Timeout: 60 * time.Second}}, nil
}

func (a *Almacen) pide(ctx context.Context, metodo, ruta string, cuerpo any, prefer string) ([]byte, error) {
	var lector *bytes.Reader
	if cuerpo != nil {
		b, err := json.Marshal(cuerpo)
		if err != nil {
			return nil, err
		}
		lector = bytes.NewReader(b)
	} else {
		lector = bytes.NewReader(nil)
	}
	req, err := http.NewRequestWithContext(ctx, metodo, a.url+"/rest/v1"+ruta, lector)
	if err != nil {
		return nil, err
	}
	req.Header.Set("apikey", a.clave)
	req.Header.Set("Authorization", "Bearer "+a.clave)
	req.Header.Set("Content-Type", "application/json")
	if prefer != "" {
		req.Header.Set("Prefer", prefer)
	}

	resp, err := a.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b := new(bytes.Buffer)
	b.ReadFrom(resp.Body)
	if resp.StatusCode >= 300 {
		// El cuerpo del error puede citar la clave en algunos casos; se recorta.
		msg := b.String()
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return nil, fmt.Errorf("PostgREST %d: %s", resp.StatusCode, msg)
	}
	return b.Bytes(), nil
}

type filaCruda struct {
	Fuente  string          `json:"fuente"`
	Hash    string          `json:"hash"`
	Payload json.RawMessage `json:"payload"`
}

// GuardaCrudo deposita el payload. Si el hash ya existe la fuente no cambio y
// no se crea fila nueva: devuelve nuevo=false sin error.
func (a *Almacen) GuardaCrudo(ctx context.Context, fuente, hash string, payload []byte) (bool, error) {
	_, err := a.pide(ctx, http.MethodPost, "/crudo",
		[]filaCruda{{Fuente: fuente, Hash: hash, Payload: payload}},
		"resolution=ignore-duplicates,return=representation")
	if err != nil {
		return false, err
	}
	// Con ignore-duplicates PostgREST devuelve [] cuando el hash ya existia.
	var devuelto []map[string]any
	b, err := a.pide(ctx, http.MethodGet,
		"/crudo?select=id&fuente=eq."+fuente+"&hash=eq."+hash+"&limit=1", nil, "")
	if err == nil {
		_ = json.Unmarshal(b, &devuelto)
	}
	return len(devuelto) > 0, nil
}

// MarcaEstado deja constancia de la ultima corrida por fuente. La interfaz lo
// usa para decir "esta fuente no responde" en vez de mostrar un vacio mudo.
func (a *Almacen) MarcaEstado(ctx context.Context, fuente string, fallo error) error {
	cambio := map[string]any{}
	if fallo == nil {
		cambio["ultimo_ok"] = time.Now().UTC().Format(time.RFC3339)
		cambio["ultimo_error"] = nil
	} else {
		msg := fallo.Error()
		if len(msg) > 400 {
			msg = msg[:400]
		}
		cambio["ultimo_error"] = msg
	}
	_, err := a.pide(ctx, http.MethodPatch, "/fuente?id=eq."+fuente, cambio, "return=minimal")
	return err
}

// Normaliza dispara la conversion de crudo a item dentro de Postgres.
func (a *Almacen) Normaliza(ctx context.Context, fuente string) (int, error) {
	b, err := a.pide(ctx, http.MethodPost, "/rpc/normalizar",
		map[string]string{"p_fuente": fuente}, "")
	if err != nil {
		return 0, err
	}
	var n int
	if err := json.Unmarshal(bytes.TrimSpace(b), &n); err != nil {
		return 0, nil // la funcion existe pero no devolvio numero; no es fatal
	}
	return n, nil
}
