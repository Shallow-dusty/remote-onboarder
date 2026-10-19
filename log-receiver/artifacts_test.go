package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestArtifactsRoundtripAndReplace(t *testing.T) {
	s, _ := newServer(t.TempDir())
	h := s.routes()
	for _, body := range []string{"full log\n中文\nline2", "replacement"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("PUT", "/artifacts/test-session/setup.log", strings.NewReader(body)))
		if w.Code != 200 {
			t.Fatalf("put %d %s", w.Code, w.Body)
		}
		var ack struct {
			SHA256 string `json:"sha256"`
			Bytes  int    `json:"bytes"`
		}
		json.Unmarshal(w.Body.Bytes(), &ack)
		sum := sha256.Sum256([]byte(body))
		if ack.SHA256 != hex.EncodeToString(sum[:]) || ack.Bytes != len([]byte(body)) {
			t.Fatal("bad ack")
		}
		r := httptest.NewRecorder()
		h.ServeHTTP(r, httptest.NewRequest("GET", "/artifacts/test-session/setup.log", nil))
		if r.Code != 200 || r.Body.String() != body {
			t.Fatal("bad roundtrip")
		}
	}
}
func TestArtifactsRejectAndRedact(t *testing.T) {
	s, _ := newServer(t.TempDir())
	h := s.routes()
	for _, path := range []string{"/artifacts/session/private.key", "/artifacts/session/", "/artifacts/bad!/setup.log"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("PUT", path, strings.NewReader("no")))
		if w.Code != 404 {
			t.Fatal(path, w.Code)
		}
	}
	key := "tskey-auth-SYNTHETIC-ONLY"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("PUT", "/artifacts/session/diagnostics.json", strings.NewReader(key)))
	r := httptest.NewRecorder()
	h.ServeHTTP(r, httptest.NewRequest("GET", "/artifacts/session/diagnostics.json", nil))
	if strings.Contains(r.Body.String(), key) {
		t.Fatal("secret retained")
	}
}
