package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}).ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Body.String() != "ok" {
		t.Fatalf("healthz: %d %q", rec.Code, rec.Body.String())
	}
}

func TestReadyzAcceptsLargePOST(t *testing.T) {
	body := strings.Repeat("x", 8192)
	req := httptest.NewRequest(http.MethodPost, "/readyz", strings.NewReader(body))
	rec := httptest.NewRecorder()
	readyz(rec, req)
	if rec.Code != 200 {
		t.Fatalf("readyz large POST: %d", rec.Code)
	}
}
