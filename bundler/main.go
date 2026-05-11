// Command brainbox-bundler — builds a sealed credential bundle for a
// brainbox session and writes the ciphertext to stdout.
//
// Invoked by the Swift Brainbox Runner when it acts as the secret
// authority. Reads a JSON request on stdin:
//
//   {"workspace_profile": "...", "workspace_home": "/path/to/profile",
//    "recipient": "age1..."}
//
// Walks the host's credential filesystem (mirrors the Python
// _resolve_profile_mounts logic), packs into a tar, zstd-compresses,
// and age-encrypts to the supplied recipient. The output format is
// identical to what `brainbox-init apply` expects on the guest side.
package main

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"filippo.io/age"
	"github.com/klauspost/compress/zstd"
)

const bundleVersion = 1

// request is the JSON shape on stdin.
type request struct {
	WorkspaceProfile string `json:"workspace_profile"`
	WorkspaceHome    string `json:"workspace_home"`
	Recipient        string `json:"recipient"`
}

// fileEntry / dirEntry / manifest mirror the Python Manifest fields exactly.
type fileEntry struct {
	Arcname string `json:"arcname"`
	Target  string `json:"target"`
	Mode    uint32 `json:"mode"`
	Size    int64  `json:"size"`
}

type dirEntry struct {
	Target string `json:"target"`
	Mode   uint32 `json:"mode"`
}

type manifest struct {
	Version   int               `json:"version"`
	Profile   string            `json:"profile"`
	CreatedAt string            `json:"created_at"`
	Files     []fileEntry       `json:"files"`
	Dirs      []dirEntry        `json:"dirs"`
	Env       map[string]string `json:"env"`
}

// sourceSpec describes one credential source. isFile=true means a single
// file (e.g. .gitconfig); isFile=false means a directory to walk.
type sourceSpec struct {
	target string
	isFile bool
}

// credPaths mirrors the set the Python _resolve_profile_mounts produces
// for delivery=bundle. Order is preserved for deterministic output.
var credPaths = []sourceSpec{
	{".aws", false},
	{".azure", false},
	{".kube", false},
	{".ssh", false},
	{".gcloud", false},
	{".terraform.d", false},
	{".codex", false},
	{".gitconfig", true},
	{".gnupg/pubring.kbx", true},
	{".gnupg/trustdb.gpg", true},
	{".aws/sso/cache", false},
}

// hostOnlyVars are env vars that must not be forwarded into the guest
// (host-specific identity, sockets, paths). Mirrors the Python set.
var hostOnlyVars = map[string]bool{
	"SSH_AUTH_SOCK":     true,
	"GIT_SSH_COMMAND":   true,
	"TMPDIR":            true,
	"SHELL":             true,
	"TERM_PROGRAM":      true,
	"TERM_SESSION_ID":   true,
	"HOME":              true,
	"USER":              true,
	"LOGNAME":           true,
	"PATH":              true,
	"PWD":               true,
	"OLDPWD":            true,
	"SHLVL":             true,
	"XDG_CONFIG_HOME":   true,
	"CLAUDE_CONFIG_DIR": true,
	"GEMINI_CONFIG_DIR": true,
}

func main() {
	var req request
	if err := json.NewDecoder(os.Stdin).Decode(&req); err != nil {
		fatalf("decode stdin: %v", err)
	}
	sealed, err := build(req)
	if err != nil {
		fatalf("%v", err)
	}
	if _, err := os.Stdout.Write(sealed); err != nil {
		fatalf("write stdout: %v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "brainbox-bundler: "+format+"\n", args...)
	os.Exit(1)
}

func build(req request) ([]byte, error) {
	if !strings.HasPrefix(req.Recipient, "age1") {
		return nil, fmt.Errorf("recipient must be an age1... pubkey")
	}
	recipient, err := age.ParseX25519Recipient(req.Recipient)
	if err != nil {
		return nil, fmt.Errorf("parse recipient: %w", err)
	}

	tarBuf := new(bytes.Buffer)
	tw := tar.NewWriter(tarBuf)

	files := []fileEntry{}
	dirs := map[string]uint32{}

	for _, spec := range credPaths {
		host := resolveHostPath(req.WorkspaceHome, spec)
		if host == "" {
			continue
		}
		if spec.isFile {
			if err := addFile(tw, host, spec.target, &files, dirs); err != nil {
				return nil, err
			}
		} else {
			if err := walkDir(tw, host, spec.target, &files, dirs); err != nil {
				return nil, err
			}
		}
	}

	env := resolveEnv(req.WorkspaceProfile, req.WorkspaceHome)

	m := manifest{
		Version:   bundleVersion,
		Profile:   req.WorkspaceProfile,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
		Files:     files,
		Dirs:      sortDirs(dirs),
		Env:       env,
	}
	manifestBytes, err := json.MarshalIndent(&m, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal manifest: %w", err)
	}
	if err := writeTar(tw, "manifest.json", manifestBytes, 0o600); err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, fmt.Errorf("close tar: %w", err)
	}

	// zstd compression — level matches Python's default in pack().
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedBetterCompression))
	if err != nil {
		return nil, fmt.Errorf("zstd encoder: %w", err)
	}
	plaintext := encoder.EncodeAll(tarBuf.Bytes(), nil)
	encoder.Close()

	// age envelope encryption.
	cipherBuf := new(bytes.Buffer)
	w, err := age.Encrypt(cipherBuf, recipient)
	if err != nil {
		return nil, fmt.Errorf("age encrypt: %w", err)
	}
	if _, err := w.Write(plaintext); err != nil {
		return nil, fmt.Errorf("age write: %w", err)
	}
	if err := w.Close(); err != nil {
		return nil, fmt.Errorf("age close: %w", err)
	}
	return cipherBuf.Bytes(), nil
}

// resolveHostPath finds the host filesystem path for a credential source.
// Prefers workspace_home; falls back to $HOME. Returns "" if not found.
func resolveHostPath(workspaceHome string, spec sourceSpec) string {
	if workspaceHome != "" {
		candidate := filepath.Join(workspaceHome, spec.target)
		if matchesType(candidate, spec.isFile) {
			return candidate
		}
	}
	home, _ := os.UserHomeDir()
	if home != "" {
		candidate := filepath.Join(home, spec.target)
		if matchesType(candidate, spec.isFile) {
			return candidate
		}
	}
	return ""
}

func matchesType(path string, isFile bool) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	if isFile {
		return !info.IsDir()
	}
	return info.IsDir()
}

// addFile adds a single file source to the tar and records its parent
// dir mode so unpack can chmod the dir on the guest.
func addFile(tw *tar.Writer, host, target string, files *[]fileEntry, dirs map[string]uint32) error {
	info, err := os.Stat(host)
	if err != nil {
		return nil
	}
	data, err := os.ReadFile(host)
	if err != nil {
		return nil
	}
	mode := uint32(info.Mode().Perm())
	arcname := "files/" + target
	*files = append(*files, fileEntry{
		Arcname: arcname,
		Target:  target,
		Mode:    mode,
		Size:    int64(len(data)),
	})
	if err := writeTar(tw, arcname, data, mode); err != nil {
		return err
	}
	// Capture parent dir mode (host-side) so the guest tightens permissions
	// to match — the Python bundle does the same for, e.g., .gnupg from
	// pubring.kbx parent.
	targetParent := filepath.Dir(target)
	if targetParent != "" && targetParent != "." {
		if parentInfo, err := os.Stat(filepath.Dir(host)); err == nil {
			dirs[filepath.ToSlash(targetParent)] = uint32(parentInfo.Mode().Perm())
		}
	}
	return nil
}

// walkDir recursively adds a directory source. Records each subdirectory's
// mode (including the root) for unpack to apply.
func walkDir(tw *tar.Writer, host, target string, files *[]fileEntry, dirs map[string]uint32) error {
	rootInfo, err := os.Stat(host)
	if err != nil {
		return nil
	}
	dirs[filepath.ToSlash(target)] = uint32(rootInfo.Mode().Perm())

	return filepath.WalkDir(host, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == host {
			return nil
		}
		rel, err := filepath.Rel(host, p)
		if err != nil {
			return nil
		}
		subTarget := target + "/" + filepath.ToSlash(rel)
		if d.IsDir() {
			info, err := d.Info()
			if err == nil {
				dirs[subTarget] = uint32(info.Mode().Perm())
			}
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		mode := uint32(info.Mode().Perm())
		arcname := "files/" + subTarget
		*files = append(*files, fileEntry{
			Arcname: arcname,
			Target:  subTarget,
			Mode:    mode,
			Size:    int64(len(data)),
		})
		return writeTar(tw, arcname, data, mode)
	})
}

// resolveEnv reads workspace_home/.env and .env.secrets, filters host-only
// vars, prepends WORKSPACE_PROFILE + WORKSPACE_HOME. Mirrors the Python
// _resolve_profile_env behavior.
func resolveEnv(profile, workspaceHome string) map[string]string {
	env := map[string]string{}
	if profile != "" {
		env["WORKSPACE_PROFILE"] = profile
	}
	env["WORKSPACE_HOME"] = "/home/developer"
	if workspaceHome == "" {
		return env
	}
	for _, name := range []string{".env", ".env.secrets"} {
		path := filepath.Join(workspaceHome, name)
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		for _, raw := range strings.Split(string(data), "\n") {
			line := strings.TrimSpace(raw)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if strings.HasPrefix(line, "export ") {
				line = line[7:]
			}
			parts := strings.SplitN(line, "=", 2)
			if len(parts) != 2 {
				continue
			}
			key := strings.TrimSpace(parts[0])
			if hostOnlyVars[key] {
				continue
			}
			env[key] = parts[1]
		}
	}
	return env
}

func writeTar(tw *tar.Writer, arcname string, data []byte, mode uint32) error {
	hdr := &tar.Header{
		Name:    arcname,
		Mode:    int64(mode),
		Size:    int64(len(data)),
		ModTime: time.Unix(0, 0),
		Format:  tar.FormatPAX,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return fmt.Errorf("write tar header %s: %w", arcname, err)
	}
	if _, err := io.Copy(tw, bytes.NewReader(data)); err != nil {
		return fmt.Errorf("write tar data %s: %w", arcname, err)
	}
	return nil
}

// sortDirs returns the dirs map as a slice ordered by depth (parents first)
// so the guest unpack applies chmods top-down.
func sortDirs(dirs map[string]uint32) []dirEntry {
	keys := make([]string, 0, len(dirs))
	for k := range dirs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		di := strings.Count(keys[i], "/")
		dj := strings.Count(keys[j], "/")
		if di != dj {
			return di < dj
		}
		return keys[i] < keys[j]
	})
	out := make([]dirEntry, 0, len(keys))
	for _, k := range keys {
		out = append(out, dirEntry{Target: k, Mode: dirs[k]})
	}
	return out
}
