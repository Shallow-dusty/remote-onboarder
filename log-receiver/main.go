package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const maxEventBytes = 1 << 20

var sessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

type event struct {
	SessionID string `json:"sessionId"`
	Sequence  int64  `json:"sequence"`
	Timestamp string `json:"timestamp,omitempty"`
	Level     string `json:"level,omitempty"`
	Step      string `json:"step,omitempty"`
	Message   string `json:"message,omitempty"`
	Computer  string `json:"computer,omitempty"`
	User      string `json:"user,omitempty"`
}

type storedEvent struct {
	event
	ReceivedAt string `json:"receivedAt"`
	RemoteIP   string `json:"remoteIp,omitempty"`
}

type sessionInfo struct {
	SessionID string `json:"sessionId"`
	Bytes     int64  `json:"bytes"`
	UpdatedAt string `json:"updatedAt"`
}

type server struct {
	dataDir string
	mu      sync.Mutex
}

func newServer(dataDir string) (*server, error) {
	if err := os.MkdirAll(dataDir, 0o750); err != nil {
		return nil, err
	}
	return &server{dataDir: dataDir}, nil
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/events", s.handleEvents)
	mux.HandleFunc("/sessions", s.handleSessions)
	mux.HandleFunc("/sessions/", s.handleSession)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		mux.ServeHTTP(w, r)
	})
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "time": time.Now().UTC().Format(time.RFC3339Nano)})
}

func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxEventBytes+1))
	if err != nil {
		http.Error(w, "read event", http.StatusBadRequest)
		return
	}
	if len(body) > maxEventBytes {
		http.Error(w, "event too large", http.StatusRequestEntityTooLarge)
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var incoming event
	if err := decoder.Decode(&incoming); err != nil {
		http.Error(w, "invalid event: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := ensureJSONEOF(decoder); err != nil {
		http.Error(w, "invalid event: "+err.Error(), http.StatusBadRequest)
		return
	}
	incoming.SessionID = strings.TrimSpace(incoming.SessionID)
	if !sessionIDPattern.MatchString(incoming.SessionID) {
		http.Error(w, "invalid sessionId", http.StatusBadRequest)
		return
	}
	if incoming.Sequence < 1 {
		http.Error(w, "sequence must be positive", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(incoming.Message) == "" {
		http.Error(w, "message is required", http.StatusBadRequest)
		return
	}
	stored := storedEvent{
		event:      incoming,
		ReceivedAt: time.Now().UTC().Format(time.RFC3339Nano),
		RemoteIP:   remoteIP(r.RemoteAddr),
	}
	encoded, err := json.Marshal(stored)
	if err != nil {
		http.Error(w, "encode event", http.StatusInternalServerError)
		return
	}
	if err := s.appendEvent(incoming.SessionID, encoded); err != nil {
		log.Printf("append %s/%d: %v", incoming.SessionID, incoming.Sequence, err)
		http.Error(w, "store event", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "received": incoming.Sequence})
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); errors.Is(err, io.EOF) {
		return nil
	} else if err != nil {
		return err
	}
	return errors.New("trailing JSON value")
}

func (s *server) appendEvent(sessionID string, encoded []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	path := filepath.Join(s.dataDir, sessionID+".jsonl")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(append(encoded, '\n')); err != nil {
		return err
	}
	return f.Sync()
}

func (s *server) handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	entries, err := os.ReadDir(s.dataDir)
	if err != nil {
		http.Error(w, "list sessions", http.StatusInternalServerError)
		return
	}
	result := make([]sessionInfo, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".jsonl" {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		result = append(result, sessionInfo{
			SessionID: strings.TrimSuffix(entry.Name(), ".jsonl"),
			Bytes:     info.Size(),
			UpdatedAt: info.ModTime().UTC().Format(time.RFC3339Nano),
		})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].UpdatedAt > result[j].UpdatedAt })
	writeJSON(w, http.StatusOK, result)
}

func (s *server) handleSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/sessions/")
	if !sessionIDPattern.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(s.dataDir, id+".jsonl")
	w.Header().Set("Content-Type", "application/x-ndjson; charset=utf-8")
	http.ServeFile(w, r, path)
}

var indexTemplate = template.Must(template.New("index").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>SSH Launchpad Logs</title>
<style>body{font:14px ui-monospace,Consolas,monospace;margin:24px;background:#111827;color:#e5e7eb}a{color:#60a5fa}button{margin:4px;padding:8px}pre{white-space:pre-wrap;background:#030712;padding:16px;border-radius:8px;max-height:70vh;overflow:auto}.muted{color:#9ca3af}</style></head>
<body><h1>SSH Launchpad live logs</h1><div id="sessions" class="muted">Loading...</div><pre id="log">Select a session.</pre>
<script>
let selected='';
async function sessions(){const r=await fetch('sessions');const xs=await r.json();document.getElementById('sessions').innerHTML=xs.map(x=>'<button onclick="pick(\''+x.sessionId+'\')">'+x.sessionId+' · '+x.updatedAt+'</button>').join('')||'No sessions yet.';}
function pick(id){selected=id;load();}
async function load(){if(!selected)return;const r=await fetch('sessions/'+encodeURIComponent(selected)+'?t='+Date.now());document.getElementById('log').textContent=await r.text();const p=document.getElementById('log');p.scrollTop=p.scrollHeight;}
setInterval(()=>{sessions();load()},2000);sessions();
</script></body></html>`))

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" || r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = indexTemplate.Execute(w, nil)
}

func methodNotAllowed(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func remoteIP(remote string) string {
	host, _, err := net.SplitHostPort(remote)
	if err == nil {
		return host
	}
	return remote
}

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	data := flag.String("data", "/data", "data directory")
	flag.Parse()
	s, err := newServer(*data)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("listening on %s; data=%s", *addr, *data)
	server := &http.Server{
		Addr:              *addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
