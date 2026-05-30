// Command app is a small production-style HTTP service used to generate
// metrics, logs, and latency/error patterns for the observability stack.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "app_requests_total",
		Help: "Total HTTP requests processed, labelled by method, path and status.",
	}, []string{"method", "path", "status"})

	requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "app_request_duration_seconds",
		Help:    "HTTP request latency in seconds.",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5},
	}, []string{"method", "path"})

	errorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "app_errors_total",
		Help: "Total HTTP responses with a 5xx status, labelled by path.",
	}, []string{"path"})

	activeRequests = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "app_active_requests",
		Help: "Number of in-flight HTTP requests.",
	})
)

// statusRecorder captures the response status so middleware can record metrics
// and structured logs after the handler returns.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// instrument wraps a handler with metrics, structured logging, and the
// active-request gauge. routePath is the stable label value (not the raw URL)
// so metric cardinality stays bounded.
func instrument(logger *slog.Logger, routePath string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()
		activeRequests.Inc()
		defer activeRequests.Dec()

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next(rec, req)

		dur := time.Since(start)
		status := strconv.Itoa(rec.status)

		requestsTotal.WithLabelValues(req.Method, routePath, status).Inc()
		requestDuration.WithLabelValues(req.Method, routePath).Observe(dur.Seconds())
		if rec.status >= 500 {
			errorsTotal.WithLabelValues(routePath).Inc()
		}

		attrs := []any{
			"method", req.Method,
			"path", req.URL.Path,
			"status", rec.status,
			"duration_ms", float64(dur.Microseconds()) / 1000.0,
			"remote_addr", req.RemoteAddr,
		}
		if rec.status >= 500 {
			logger.Error("request failed", attrs...)
		} else {
			logger.Info("request handled", attrs...)
		}
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// queryInt reads an integer query parameter, returning def when the parameter
// is absent or not a valid integer.
func queryInt(r *http.Request, key string, def int) int {
	if v := r.URL.Query().Get(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// clampInt bounds v to the inclusive range [lo, hi] so the load endpoints
// cannot be asked to run unboundedly long or allocate unbounded memory.
func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	addr := ":8080"
	if v := os.Getenv("APP_LISTEN_ADDR"); v != "" {
		addr = v
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/", instrument(logger, "/", func(w http.ResponseWriter, r *http.Request) {
		// Treat anything that is not an exact "/" as not found so the catch-all
		// route does not silently absorb unknown paths.
		if r.URL.Path != "/" {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{
			"service": "project-observability-app",
			"message": "ok",
		})
	}))

	mux.HandleFunc("/health", instrument(logger, "/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "healthy"})
	}))

	mux.HandleFunc("/slow", instrument(logger, "/slow", func(w http.ResponseWriter, r *http.Request) {
		// Random latency between 50ms and 1000ms to exercise the histogram and
		// the SlowResponseTime alert. The 1s ceiling lands p95 around 0.95s,
		// comfortably above the alert threshold so it fires cleanly.
		delay := time.Duration(50+rand.Intn(951)) * time.Millisecond
		time.Sleep(delay)
		writeJSON(w, http.StatusOK, map[string]any{
			"status":   "ok",
			"slept_ms": delay.Milliseconds(),
		})
	}))

	mux.HandleFunc("/cpu", instrument(logger, "/cpu", func(w http.ResponseWriter, r *http.Request) {
		// Burn CPU on every core for ?seconds (default 30, max 600) to drive the
		// container CPU metrics and HighCPUUsage alert. Blocks for the duration.
		seconds := clampInt(queryInt(r, "seconds", 30), 1, 600)
		workers := runtime.NumCPU()
		deadline := time.Now().Add(time.Duration(seconds) * time.Second)
		var wg sync.WaitGroup
		for i := 0; i < workers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				x := 0.0001
				for time.Now().Before(deadline) {
					// Tight maths loop keeps the core hot; result discarded.
					for n := 0; n < 1_000_000; n++ {
						x = x*1.000001 + 0.000001
					}
				}
				_ = x
			}()
		}
		wg.Wait()
		writeJSON(w, http.StatusOK, map[string]any{
			"status":         "ok",
			"burned_seconds": seconds,
			"workers":        workers,
		})
	}))

	mux.HandleFunc("/mem", instrument(logger, "/mem", func(w http.ResponseWriter, r *http.Request) {
		// Allocate ?mb (default 460, max 480) and hold for ?seconds (default
		// 150, max 600) so resident memory crosses 85% of the 512m limit
		// (~460MB is ~90%) and HighMemoryUsage fires, with headroom before the
		// OOM killer.
		mb := clampInt(queryInt(r, "mb", 460), 1, 480)
		seconds := clampInt(queryInt(r, "seconds", 150), 1, 600)
		block := make([]byte, mb*1024*1024)
		// Touch one byte per 4KB page so the kernel actually backs the pages
		// with RAM; without this the mapping stays lazy and usage never rises.
		for i := 0; i < len(block); i += 4096 {
			block[i] = byte(i)
		}
		time.Sleep(time.Duration(seconds) * time.Second)
		// Keep the slice live across the sleep so the GC cannot reclaim it.
		runtime.KeepAlive(block)
		writeJSON(w, http.StatusOK, map[string]any{
			"status":  "ok",
			"held_mb": mb,
			"seconds": seconds,
		})
	}))

	mux.HandleFunc("/error", instrument(logger, "/error", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "intentional error for alert demonstration",
		})
	}))

	// /metrics is intentionally not wrapped so scrape traffic does not pollute
	// the application request metrics.
	mux.Handle("/metrics", promhttp.Handler())

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Graceful shutdown on SIGINT/SIGTERM so docker stop drains in flight work.
	go func() {
		logger.Info("server starting", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server error", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	logger.Info("server shutting down")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("graceful shutdown failed", "err", err)
	}
}
