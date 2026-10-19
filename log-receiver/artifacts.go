package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

const maxArtifactBytes = 32 << 20
const maxArtifactStorage = 512 << 20

var artifactNames = map[string]bool{"setup.log": true, "events.jsonl": true, "diagnostics.json": true, "openssh-msi.log": true, "tailscale-msi.log": true, "connection.txt": true, "upload-status.json": true}

// Artifacts are UTF-8, client-redacted tool logs, never arbitrary paths or archives.
// This endpoint, like the event API, must only be exposed through private Tailnet.
func (s *server) handleArtifacts(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/artifacts/"), "/")
	if len(parts) != 2 || !sessionIDPattern.MatchString(parts[0]) || !artifactNames[parts[1]] {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(s.dataDir, "artifacts", parts[0], parts[1])
	if r.Method == http.MethodGet {
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Disposition", "attachment; filename="+parts[1])
		http.ServeFile(w, r, path)
		return
	}
	if r.Method != http.MethodPut {
		methodNotAllowed(w, "GET, PUT")
		return
	}
	// Restrict body size before memory allocation. Exact credential redaction happens
	// at the client; pattern redaction is a second defense for Tailscale keys.
	body, err := io.ReadAll(io.LimitReader(r.Body, maxArtifactBytes+1))
	if err != nil {
		http.Error(w, "read artifact", 400)
		return
	}
	if len(body) > maxArtifactBytes {
		http.Error(w, "artifact too large; keep local copy", 413)
		return
	}
	body = authKeyPattern.ReplaceAll(body, []byte("[REDACTED]"))
	s.mu.Lock()
	defer s.mu.Unlock()
	root := filepath.Join(s.dataDir, "artifacts")
	if err = os.MkdirAll(root, 0700); err != nil {
		http.Error(w, "storage unavailable", 500)
		return
	}
	var total int64
	sessions, err := os.ReadDir(root)
	if err != nil {
		http.Error(w, "storage unavailable", 500)
		return
	}
	existing := false
	for _, entry := range sessions {
		if entry.Name() == parts[0] {
			existing = true
		}
	}
	if !existing && len(sessions) >= maxSessions {
		http.Error(w, "session quota", 507)
		return
	}
	err = filepath.WalkDir(root, func(p string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if d.Type()&os.ModeSymlink != 0 {
			return errors.New("linked storage")
		}
		if !d.IsDir() {
			i, e := d.Info()
			if e != nil {
				return e
			}
			if !i.Mode().IsRegular() {
				return errors.New("nonregular storage")
			}
			if p != path {
				total += i.Size()
			}
		}
		return nil
	})
	if err != nil {
		http.Error(w, "storage inventory failed", 500)
		return
	}
	if total+int64(len(body)) > maxArtifactStorage {
		http.Error(w, "artifact storage quota", 507)
		return
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		http.Error(w, "create session", 500)
		return
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".upload-")
	if err != nil {
		http.Error(w, "create upload", 500)
		return
	}
	defer os.Remove(f.Name())
	_, err = f.Write(body)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(f.Name(), path)
	}
	if err != nil {
		http.Error(w, "persist artifact", 500)
		return
	}
	sum := sha256.Sum256(body)
	writeJSON(w, 200, map[string]any{"ok": true, "bytes": len(body), "sha256": hex.EncodeToString(sum[:]), "name": parts[1]})
}
