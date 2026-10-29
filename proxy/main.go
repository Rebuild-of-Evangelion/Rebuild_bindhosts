// bindhosts proxy daemon
//
// Listens on 127.0.0.1:443 and decides per request path:
//
//	mock    <path> [body]   answer locally, no upstream
//	forward <path>          pass through to the real server
//	block   <path>          close the connection
//	patch   <path> <json>   rewrite request body keys, then forward
//
// Anything without a matching rule is forwarded.
//
// Certificates: the CA is generated on device and leaf certs are signed on
// demand per SNI. Only domains declared by a hosts line in the rules file get a
// cert; everything else is dropped. Ad domains that hosts maps to 0.0.0.0 also
// land on 127.0.0.1, so they must be rejected or the ad blocking is undone.
//
// Two things to keep in mind:
//  1. Upstream lookups cannot use the system resolver: hosts already points the
//     target domain at 127.0.0.1, so resolving through it loops back here.
//     Queries go straight to 223.5.5.5 instead.
//  2. Upstream certificate checks need the system trust store. Go's
//     SystemCertPool finds nothing on Android, so read /etc/security/cacerts
//     directly.
package main

import (
	"context"
	"crypto/tls"
	"bytes"
	"encoding/json"
	"crypto/x509"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

type rule struct {
	action string // mock / forward / block
	path   string
	body   string
	prefix bool
}

var (
	rulesMu        sync.RWMutex
	rules          []rule
	allowedDomains = map[string]bool{}

	dnsServer string
	roots     *x509.CertPool
	upstream  *http.Transport
)

func main() {
	listen := flag.String("listen", "127.0.0.1:443", "listen address")
	certDir := flag.String("certdir", "/data/adb/bindhosts/proxy/certs", "directory holding the local CA")
	ruleFile := flag.String("rules", "/data/adb/bindhosts/proxy.rules", "rule file")
	dnsAddr := flag.String("dns", "223.5.5.5:53", "resolver for upstream lookups")
	resolveHost := flag.String("resolve", "", "resolve this host and print its IPs, then exit")
	genca := flag.String("genca", "", "generate a local CA into this directory, print the trust store filename, then exit")
	flag.Parse()

	log.SetFlags(log.LstdFlags)
	log.SetPrefix("[proxy] ")

	dnsServer = *dnsAddr

// genCA writes a CA and exits; the script installs it into the trust store
	if *genca != "" {
		name, err := genCA(*genca)
		if err != nil {
			log.Fatalf("genca: %v", err)
		}
		fmt.Println(name)
		return
	}

	if *resolveHost != "" {
		ips, err := lookup(*resolveHost)
		if err != nil {
			fmt.Fprintf(os.Stderr, "resolve %s: %v\n", *resolveHost, err)
			os.Exit(1)
		}
		for _, ip := range ips {
			fmt.Println(ip)
		}
		return
	}

	ca, err := loadCA(*certDir)
	if err != nil {
		log.Fatalf("no usable CA in %s: %v (run -genca first)", *certDir, err)
	}

	loadRules(*ruleFile)
	roots = loadSystemRoots()

	upstream = &http.Transport{
		DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, _, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips, err := lookup(host)
			if err != nil || len(ips) == 0 {
				return nil, fmt.Errorf("resolve %s: %w", host, err)
			}
			d := &net.Dialer{Timeout: 10 * time.Second}
			return tls.DialWithDialer(d, "tcp", net.JoinHostPort(ips[0], "443"), &tls.Config{
				ServerName: host,
				RootCAs:    roots,
				NextProtos: []string{"http/1.1"},
				MinVersion: tls.VersionTLS12,
			})
		},
		ForceAttemptHTTP2:   false,
		MaxIdleConnsPerHost: 8,
		IdleConnTimeout:     60 * time.Second,
	}

// SIGHUP re-reads the rules without restarting the process
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP)
	go func() {
		for range sig {
			log.Printf("SIGHUP: reloading rules")
			loadRules(*ruleFile)
		}
	}()

// Serve h2 and http/1.1: honour h2 when offered, otherwise fall back
	protos := new(http.Protocols)
	protos.SetHTTP1(true)
	protos.SetHTTP2(true)

	srv := &http.Server{
		Addr:      *listen,
		Handler:   http.HandlerFunc(handle),
		Protocols: protos,
		TLSConfig: &tls.Config{
// Signed on demand per SNI; getCertificate enforces the allow list
			GetCertificate: ca.getCertificate(isAllowed),
			NextProtos:     []string{"h2", "http/1.1"},
			MinVersion:     tls.VersionTLS12,
		},
		ReadHeaderTimeout: 15 * time.Second,
	}

	log.Printf("listening on %s, domains %v", *listen, allowedList())
	if err := srv.ListenAndServeTLS("", ""); err != nil {
		log.Fatal(err)
	}
}

func logf(format string, args ...any) {
	log.Printf(format, args...)
}

// isAllowed reports whether a domain was declared by a hosts line in the rules
func isAllowed(sni string) bool {
	rulesMu.RLock()
	defer rulesMu.RUnlock()
	return allowedDomains[strings.ToLower(sni)]
}

func allowedList() []string {
	rulesMu.RLock()
	defer rulesMu.RUnlock()
	out := make([]string, 0, len(allowedDomains))
	for k := range allowedDomains {
		out = append(out, k)
	}
	return out
}

// loadRules parses the rules file:
//   one rule per line: <action> <path> [body]
//   lines starting with a digit are hosts entries: 127.0.0.1 <domain>...
func loadRules(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("no rules (%v), everything will be forwarded", err)
		rulesMu.Lock()
		rules = nil
		allowedDomains = map[string]bool{}
		rulesMu.Unlock()
		return
	}

	var loaded []rule
	domains := map[string]bool{}

	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

// hosts line: 127.0.0.1 a.com b.com
		if line[0] >= '0' && line[0] <= '9' {
			fields := strings.Fields(line)
			for _, f := range fields[1:] {
				domains[strings.ToLower(f)] = true
			}
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 2 {
			log.Printf("skip malformed rule: %s", line)
			continue
		}
		action := fields[0]
		if action != "mock" && action != "forward" && action != "block" && action != "patch" {
			log.Printf("skip unknown action: %s", line)
			continue
		}
		p := fields[1]
		prefix := strings.HasSuffix(p, "*")
		p = strings.TrimSuffix(p, "*")
		body := ""
		if idx := strings.Index(line, fields[1]); idx >= 0 {
			rest := strings.TrimSpace(line[idx+len(fields[1]):])
			if !strings.HasPrefix(rest, "#") {
				body = rest
			}
		}
		loaded = append(loaded, rule{action: action, path: p, body: body, prefix: prefix})
		log.Printf("rule: %-7s %s%s", action, p, map[bool]string{true: "*", false: ""}[prefix])
	}

	rulesMu.Lock()
	rules = loaded
	allowedDomains = domains
	rulesMu.Unlock()

	log.Printf("loaded %d rules, %d domains", len(loaded), len(domains))
}

// match returns the first rule that matches, top to bottom
func match(path string) *rule {
	rulesMu.RLock()
	defer rulesMu.RUnlock()
	for i := range rules {
		r := &rules[i]
		if r.prefix {
			if strings.HasPrefix(path, r.path) {
				return r
			}
		} else if path == r.path {
			return r
		}
	}
	return nil
}

func handle(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	hit := match(path)

	if hit != nil && hit.action == "block" {
		log.Printf("BLOCK %s", path)
		if hj, ok := w.(http.Hijacker); ok {
			if conn, _, err := hj.Hijack(); err == nil {
				conn.Close()
				return
			}
		}
		w.WriteHeader(http.StatusForbidden)
		return
	}

	if hit != nil && hit.action == "mock" {
		log.Printf("MOCK  %s %s", r.Method, path)
		body := hit.body
		if body == "" {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, body)
		return
	}

	patchBodyStr := ""
	if hit != nil && hit.action == "patch" {
		patchBodyStr = hit.body
	}
	forward(w, r, patchBodyStr)
}

func forward(w http.ResponseWriter, r *http.Request, patchBodyStr string) {
	host := r.Host
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("read body: %v", err)
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	r.Body.Close()

	if patchBodyStr != "" {
		if merged, perr := patchBody(body, patchBodyStr); perr == nil {
			body = merged
			log.Printf("PATCH %s %s", r.Method, r.URL.Path)
		} else {
			log.Printf("PATCH %s %s skipped: %v", r.Method, r.URL.Path, perr)
		}
	}


	req, err := http.NewRequestWithContext(r.Context(), r.Method,
		"https://"+host+r.URL.RequestURI(), strings.NewReader(string(body)))
	if err != nil {
		log.Printf("build request: %v", err)
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	for k, vs := range r.Header {
		switch strings.ToLower(k) {
		case "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
			"te", "trailers", "transfer-encoding", "upgrade", "content-length", "host":
			continue
		}
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}

	resp, err := upstream.RoundTrip(req)
	if err != nil {
		log.Printf("FWD   %s %s FAILED: %v", r.Method, r.URL.Path, err)
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for k, vs := range resp.Header {
		switch strings.ToLower(k) {
		case "connection", "keep-alive", "transfer-encoding":
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}

// Stream the response instead of buffering it whole.
// Pass Content-Length through when upstream gave one; leave it unset for chunked (-1)
	if resp.ContentLength >= 0 {
		w.Header().Set("Content-Length", fmt.Sprint(resp.ContentLength))
	}

	w.WriteHeader(resp.StatusCode)

	n, err := io.Copy(w, resp.Body)
	if err != nil {
// Headers are already sent, the status code cannot change now
		log.Printf("FWD   %s %s copy aborted after %d B: %v", r.Method, r.URL.Path, n, err)
		return
	}

	log.Printf("FWD   %s %s -> %d (%d B)", r.Method, r.URL.Path, resp.StatusCode, n)
}

// loadSystemRoots reads the Android trust store.
// SystemCertPool finds nothing on Android, so walk the directory instead.
func loadSystemRoots() *x509.CertPool {
	pool := x509.NewCertPool()
	dirs := []string{
		"/apex/com.android.conscrypt/cacerts",
		"/system/etc/security/cacerts",
	}
	loaded := 0
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			data, err := os.ReadFile(dir + "/" + e.Name())
			if err != nil {
				continue
			}
			if block, _ := pem.Decode(data); block != nil {
				if cert, err := x509.ParseCertificate(block.Bytes); err == nil {
					pool.AddCert(cert)
					loaded++
				}
				continue
			}
			if cert, err := x509.ParseCertificate(data); err == nil {
				pool.AddCert(cert)
				loaded++
			}
		}
	}
	log.Printf("loaded %d system roots", loaded)
	if loaded == 0 {
		log.Printf("WARNING: no system roots loaded, upstream verification will fail")
	}
	return pool
}


// patchBody replaces the value of each key present in patchJSON, leaving every
// other byte of the body untouched. Field order, number formatting and
// whitespace all survive, so a server that signs the body keeps working.
func patchBody(body []byte, patchJSON string) ([]byte, error) {
	var patch map[string]json.RawMessage
	if err := json.Unmarshal([]byte(patchJSON), &patch); err != nil {
		return nil, err
	}
	out := body
	for k, v := range patch {
		out = replaceKey(out, k, v)
	}
	return out, nil
}

// replaceKey finds "key": in body and swaps the value that follows it.
func replaceKey(body []byte, key string, val json.RawMessage) []byte {
	needle := []byte(`"` + key + `":`)
	idx := bytes.Index(body, needle)
	if idx < 0 {
		return body
	}
	start := idx + len(needle)
	for start < len(body) && (body[start] == ' ' || body[start] == '\t') {
		start++
	}
	end := scanValue(body, start)
	if end < 0 {
		return body
	}
	out := make([]byte, 0, len(body)+len(val))
	out = append(out, body[:start]...)
	out = append(out, val...)
	out = append(out, body[end:]...)
	return out
}

// scanValue returns the index just past the JSON value starting at i.
func scanValue(b []byte, i int) int {
	if i >= len(b) {
		return -1
	}
	switch b[i] {
	case '"':
		i++
		for i < len(b) {
			if b[i] == '\\' {
				i += 2
				continue
			}
			if b[i] == '"' {
				return i + 1
			}
			i++
		}
		return -1
	case '{', '[':
		depth := 0
		inStr := false
		for i < len(b) {
			c := b[i]
			if inStr {
				if c == '\\' {
					i += 2
					continue
				}
				if c == '"' {
					inStr = false
				}
			} else {
				switch c {
				case '"':
					inStr = true
				case '{', '[':
					depth++
				case '}', ']':
					depth--
					if depth == 0 {
						return i + 1
					}
				}
			}
			i++
		}
		return -1
	default:
		for i < len(b) {
			switch b[i] {
			case ',', '}', ']', ' ', '\t', '\n', '\r':
				return i
			}
			i++
		}
		return len(b)
	}
}
