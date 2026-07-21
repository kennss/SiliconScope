//
//  File:      security.go
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Agent-side security for the fleet HTTP endpoint: a persisted bearer token (auth) and
//             a self-signed TLS certificate (encryption), both auto-generated on first run and
//             stored under a writable config dir. Exposes the cert's SHA-256 fingerprint so the Mac
//             can TOFU-pin it (advertised in the mDNS TXT). /metrics requires the token; /healthz
//             stays open for discovery/liveness.
//  Notes:     Config dir resolution: $SSCOPE_CONFIG_DIR -> $STATE_DIRECTORY (systemd StateDirectory=)
//             -> os.UserConfigDir()/sscope-agent -> /etc/sscope-agent. Token = 32 random bytes,
//             base64url. Cert = self-signed ECDSA P-256, ~10y, SANs = hostname + local IPs (SANs are
//             cosmetic under TOFU pinning, which ignores hostname checks). Fingerprint = SHA-256 of
//             the leaf DER, lowercase hex. Token compare is constant-time.
//
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// configDir resolves a writable directory for the token + TLS material, preferring an explicit
// override, then systemd's StateDirectory, then the user config dir, then a system fallback.
func configDir() string {
	if d := os.Getenv("SSCOPE_CONFIG_DIR"); d != "" {
		return d
	}
	if d := os.Getenv("STATE_DIRECTORY"); d != "" { // set by systemd StateDirectory=sscope-agent
		return d
	}
	if d, err := os.UserConfigDir(); err == nil {
		return filepath.Join(d, "sscope-agent")
	}
	return "/etc/sscope-agent"
}

// loadOrCreateToken returns the bearer token, generating and persisting one (0600) on first run.
func loadOrCreateToken() (string, error) {
	path := filepath.Join(configDir(), "token")
	if b, err := os.ReadFile(path); err == nil {
		if t := strings.TrimSpace(string(b)); t != "" {
			return t, nil
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	tok := base64.RawURLEncoding.EncodeToString(raw)
	if err := os.MkdirAll(configDir(), 0o700); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		return "", err
	}
	return tok, nil
}

// loadOrCreateTLS returns a self-signed certificate (generating and persisting it on first run)
// together with its SHA-256 fingerprint (lowercase hex) for the Mac to TOFU-pin.
func loadOrCreateTLS() (tls.Certificate, string, error) {
	dir := configDir()
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")

	if cert, err := tls.LoadX509KeyPair(certPath, keyPath); err == nil {
		return cert, certFingerprint(cert), nil
	}

	certPEM, keyPEM, err := generateSelfSigned()
	if err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return tls.Certificate{}, "", err
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	return cert, certFingerprint(cert), nil
}

// generateSelfSigned mints a ~10-year self-signed ECDSA P-256 cert for the agent host.
func generateSelfSigned() (certPEM, keyPEM []byte, err error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}
	host, _ := os.Hostname()
	tmpl := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "sscope-agent"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{host, host + ".local"},
	}
	if addrs, e := net.InterfaceAddrs(); e == nil {
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
				tmpl.IPAddresses = append(tmpl.IPAddresses, ipnet.IP)
			}
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		return nil, nil, err
	}
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return nil, nil, err
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}

// certFingerprint is the SHA-256 of the leaf certificate's DER bytes, lowercase hex.
func certFingerprint(cert tls.Certificate) string {
	if len(cert.Certificate) == 0 {
		return ""
	}
	sum := sha256.Sum256(cert.Certificate[0])
	return hex.EncodeToString(sum[:])
}

// requireToken wraps a handler so it only runs for requests bearing the correct token. The compare
// is constant-time. Discovery/liveness (/healthz) is intentionally left unauthenticated.
func requireToken(token string, next http.HandlerFunc) http.HandlerFunc {
	want := []byte("Bearer " + token)
	return func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		if subtle.ConstantTimeCompare(got, want) != 1 {
			w.Header().Set("WWW-Authenticate", `Bearer realm="sscope-agent"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}
