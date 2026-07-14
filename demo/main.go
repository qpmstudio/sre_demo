package main

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

var startedAt = time.Now()

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)

	log.Printf("demo-app listening on :8080, started at %s", startedAt.Format(time.RFC3339))
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status":     "ok",
		"started_at": startedAt.Format(time.RFC3339),
	})
}
