// edge-echo is a small production-shaped HTTP service used as the
// sample origin behind Cloudflare Tunnel.
//
// It exists to demonstrate:
//   - a non-root distroless image
//   - liveness / readiness / metrics
//   - that the process binds LISTEN_ADDR (default :8080) and never
//     needs a public host port
package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequests = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "edge_echo_requests_total",
			Help: "HTTP requests by path and code.",
		},
		[]string{"path", "code"},
	)
	httpSeconds = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "edge_echo_request_duration_seconds",
			Help:    "Request duration.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"path"},
	)
)

func init() {
	prometheus.MustRegister(httpRequests, httpSeconds)
}

func main() {
	listen := getenv("LISTEN_ADDR", ":8080")
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/readyz", readyz)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/", echo(logger))

	srv := &http.Server{
		Addr:              listen,
		Handler:           withMetrics(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		BaseContext: func(_ net.Listener) context.Context {
			return context.Background()
		},
	}

	go func() {
		logger.Info("listen", "addr", listen, "uid", os.Getuid())
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("listen", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

func echo(logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		resp := map[string]any{
			"service":   "edge-echo",
			"method":    r.Method,
			"path":      r.URL.Path,
			"bytes":     len(body),
			"remote":    r.RemoteAddr, // cluster / tunnel hop, not the user
			"cf_ray":    r.Header.Get("CF-Ray"),
			"forwarded": r.Header.Get("CF-Connecting-IP"),
			"uid":       os.Getuid(),
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(resp); err != nil {
			logger.Error("encode", "err", err)
		}
	}
}

func readyz(w http.ResponseWriter, r *http.Request) {
	// Used as the large-POST synthetic. We accept the body and drop it
	// so Prometheus can send 8 KiB without the app caring.
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 1<<20))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}

func withMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusWriter{ResponseWriter: w, code: 200}
		next.ServeHTTP(rw, r)
		path := r.URL.Path
		httpRequests.WithLabelValues(path, http.StatusText(rw.code)).Inc()
		httpSeconds.WithLabelValues(path).Observe(time.Since(start).Seconds())
	})
}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (w *statusWriter) WriteHeader(code int) {
	w.code = code
	w.ResponseWriter.WriteHeader(code)
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
