package main

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEventRoundTrip(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	s, err := newServer(root)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	payload := `{"sessionId":"test-001","sequence":1,"timestamp":"2026-09-04T00:00:00Z","level":"INFO","step":"preflight","message":"started","computer":"PC","user":"alice"}`
	resp, err := http.Post(ts.URL+"/events", "application/json", strings.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}

	f, err := os.Open(filepath.Join(root, "test-001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	if !scanner.Scan() {
		t.Fatal("missing stored event")
	}
	var stored storedEvent
	if err := json.Unmarshal(scanner.Bytes(), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.SessionID != "test-001" || stored.Sequence != 1 || stored.ReceivedAt == "" {
		t.Fatalf("unexpected event: %+v", stored)
	}
}

func TestRejectsInvalidEvents(t *testing.T) {
	t.Parallel()
	s, err := newServer(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for name, payload := range map[string]string{
		"bad session":     `{"sessionId":"../escape","sequence":1,"message":"x"}`,
		"bad sequence":    `{"sessionId":"ok","sequence":0,"message":"x"}`,
		"missing message": `{"sessionId":"ok","sequence":1}`,
		"unknown field":   `{"sessionId":"ok","sequence":1,"message":"x","secret":"no"}`,
		"trailing json":   `{"sessionId":"ok","sequence":1,"message":"x"}{}`,
	} {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/events", strings.NewReader(payload))
			w := httptest.NewRecorder()
			s.routes().ServeHTTP(w, req)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
		})
	}
}

func TestHealthAndSessionList(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "abc.jsonl"), []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := newServer(root)
	if err != nil {
		t.Fatal(err)
	}

	for _, path := range []string{"/healthz", "/sessions", "/"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		s.routes().ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("%s: status=%d", path, w.Code)
		}
	}
}
