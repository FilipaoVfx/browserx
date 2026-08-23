// Comando rastreo: trae el payload de una fuente del ecosistema y lo deposita
// en Supabase, sin normalizar.
//
//	rastreo corag            trae y guarda
//	rastreo corag --seco     trae e informa, sin escribir ni credenciales
//	rastreo --todas          recorre las cuatro fuentes
//
// Corre en GitHub Actions por cron. Vercel Hobby limita cron a una vez al dia y
// Cloudflare Workers da 10 ms de CPU sin Go nativo, asi que Actions es la unica
// opcion gratuita que sostiene umbrales de 6 horas.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"
)

func main() {
	seco := flag.Bool("seco", false, "trae e informa sin escribir; no requiere credenciales")
	todas := flag.Bool("todas", false, "recorre todas las fuentes")
	flag.Parse()

	var ids []string
	switch {
	case *todas:
		for id := range fuentes {
			ids = append(ids, id)
		}
		sort.Strings(ids)
	case flag.NArg() == 1:
		ids = []string{flag.Arg(0)}
	default:
		fmt.Fprintf(os.Stderr, "uso: rastreo <fuente> | --todas [--seco]\nfuentes: ")
		var d []string
		for id := range fuentes {
			d = append(d, id)
		}
		sort.Strings(d)
		fmt.Fprintln(os.Stderr, d)
		os.Exit(2)
	}

	ctx, cancelar := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancelar()

	var almacen *Almacen
	if !*seco {
		var err error
		if almacen, err = NuevoAlmacen(); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
	}

	fallos := 0
	for _, id := range ids {
		if err := correr(ctx, almacen, id, *seco); err != nil {
			fmt.Fprintf(os.Stderr, "  %s: %v\n", id, err)
			fallos++
			// Una fuente caida no arrastra a las demas: es el punto de tener
			// un rastreo por fuente en vez de uno solo para todas.
			if almacen != nil {
				_ = almacen.MarcaEstado(ctx, id, err)
			}
		}
	}
	if fallos > 0 {
		fmt.Fprintf(os.Stderr, "\n%d de %d fuentes fallaron\n", fallos, len(ids))
		os.Exit(1)
	}
}

func correr(ctx context.Context, a *Almacen, id string, seco bool) error {
	f, ok := fuentes[id]
	if !ok {
		return fmt.Errorf("fuente desconocida")
	}
	paginas := f.Paginas()
	inicio := time.Now()
	fmt.Printf("%s: %d peticion(es)\n", id, len(paginas))

	var bytesTotal, vacias, nuevas int
	for i, url := range paginas {
		if i > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(pausa):
			}
		}
		cuerpo, err := Trae(ctx, url)
		if err != nil {
			return err
		}
		bytesTotal += len(cuerpo)

		// Un payload sin contenido util no merece fila: sigad devuelve HTTP 200
		// con cero features cuando el bbox no cuadra con el zoom.
		if vacio(cuerpo) {
			vacias++
			continue
		}
		if seco {
			nuevas++
			continue
		}
		esNueva, err := a.GuardaCrudo(ctx, id, Hash(cuerpo), cuerpo)
		if err != nil {
			return err
		}
		if esNueva {
			nuevas++
		}
	}

	fmt.Printf("  %d KB | %d con datos | %d vacias | %.1fs\n",
		bytesTotal/1024, nuevas, vacias, time.Since(inicio).Seconds())

	if seco {
		return nil
	}
	if err := a.MarcaEstado(ctx, id, nil); err != nil {
		return err
	}
	n, err := a.Normaliza(ctx, id)
	if err != nil {
		return fmt.Errorf("normalizacion: %w", err)
	}
	fmt.Printf("  %d items normalizados\n", n)
	return nil
}

// vacio reconoce las respuestas 200 que no traen nada: lista vacia, objeto sin
// coleccion, o GeoJSON sin features. sigad devuelve exactamente esto cuando el
// bbox no cuadra con el zoom, y sin error.
func vacio(b []byte) bool {
	s := strings.TrimSpace(string(b))
	if len(s) < 3 || s == "[]" || s == "{}" {
		return true
	}
	return strings.Contains(s, `"features":[]`) || strings.Contains(s, `"features": []`)
}
