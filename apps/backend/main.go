package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	version    = getenv("VERSION", "v1")
	port       = getenv("PORT", "5678")
	failRate   = parseFloat(getenv("FAIL_RATE", "0"))
	latencyMs  = parseInt(getenv("LATENCY_MS", "0"))

	requestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests by version and status.",
		},
		[]string{"version", "status"},
	)

	requestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration by version.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		},
		[]string{"version"},
	)
)

func main() {
	http.HandleFunc("/healthz", healthzHandler)
	http.HandleFunc("/", handler)
	http.Handle("/metrics", promhttp.Handler())

	log.Printf("atlas-backend version=%s listening on :%s (fail_rate=%.2f latency_ms=%d)",
		version, port, failRate, latencyMs)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	if latencyMs > 0 {
		time.Sleep(time.Duration(latencyMs) * time.Millisecond)
	}

	status := "200"
	if failRate > 0 && rand.Float64() < failRate {
		status = "500"
		http.Error(w, `{"error":"injected failure"}`, http.StatusInternalServerError)
	} else {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"version": version,
			"status":  "healthy",
			"service": "backend-api",
		})
	}

	requestsTotal.WithLabelValues(version, status).Inc()
	requestDuration.WithLabelValues(version).Observe(time.Since(start).Seconds())
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"version": version,
	})
}

func getenv(k, def string) string {
	if v, ok := os.LookupEnv(k); ok {
		return v
	}
	return def
}

func parseFloat(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

func parseInt(s string) int {
	i, _ := strconv.Atoi(s)
	return i
}

func init() {
	rand.Seed(time.Now().UnixNano())
	fmt.Fprintf(os.Stderr, "init complete\n")
}
