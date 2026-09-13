package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSessionQuotaAndNoCache(t *testing.T) {
	root := t.TempDir()
	s, err := newServer(root)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "full.jsonl")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxSessionBytes); err != nil {
		t.Fatal(err)
	}
	file.Close()
	req := httptest.NewRequest(http.MethodPost, "/events", strings.NewReader(`{"sessionId":"full","sequence":1,"message":"next"}`))
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, req)
	if w.Code != http.StatusInsufficientStorage {
		t.Fatalf("quota status %d", w.Code)
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("identity records cacheable")
	}
	info, _ := os.Stat(path)
	if info.Size() != maxSessionBytes {
		t.Fatal("quota wrote bytes")
	}
}

func TestSecretsAreRedactedAndOversizeIsRejected(t *testing.T) {
	root := t.TempDir()
	s, _ := newServer(root)
	key := "tskey-auth-" + "synthetic-test-only"
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest("POST", "/events", strings.NewReader(`{"sessionId":"ok","sequence":1,"message":"failure `+key+`"}`)))
	if w.Code != http.StatusOK {
		t.Fatal(w.Code)
	}
	data, _ := os.ReadFile(filepath.Join(root, "ok.jsonl"))
	if strings.Contains(string(data), key) {
		t.Fatal("auth key persisted")
	}
	w = httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest("POST", "/events", strings.NewReader(strings.Repeat("x", maxEventBytes+1))))
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatal(w.Code)
	}
}

func TestDoesNotReadOrAppendSymlink(t *testing.T) {
	root := t.TempDir()
	other := filepath.Join(t.TempDir(), "private")
	os.WriteFile(other, []byte("private"), 0600)
	if err := os.Symlink(other, filepath.Join(root, "linked.jsonl")); err != nil {
		t.Skip("symlinks unavailable")
	}
	s, _ := newServer(root)
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest("GET", "/sessions/linked", nil))
	if w.Code != http.StatusNotFound {
		t.Fatal(w.Code)
	}
	if err := s.appendEvent("linked", []byte("{}")); err == nil {
		t.Fatal("followed link")
	}
	data, _ := os.ReadFile(other)
	if string(data) != "private" {
		t.Fatal("modified linked file")
	}
}

func TestDashboardUsesDOMAndExposesRecoveryControls(t *testing.T) {
	for _, want := range []string{`id="search"`, `id="pause"`, `id="follow"`, `role="status"`, `document.createElement`, `document.hidden`, `response.ok`} {
		if !strings.Contains(dashboardHTML, want) {
			t.Fatal(want)
		}
	}
	if strings.Contains(dashboardHTML, "innerHTML") || strings.Contains(dashboardHTML, "onclick=") {
		t.Fatal("unsafe HTML construction")
	}
}
