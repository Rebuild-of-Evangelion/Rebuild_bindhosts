package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// CA and leaf certificates.
//
// The private key is generated on device; no key ships in the module.
// A shared key would let anyone who unpacks the module MITM the target domains.
//
// Leaf certs are signed on demand per SNI, valid 90 days, cached in memory only.
// Domains come from hosts lines in the rules file, never hardcoded.

const (
	caCertFile = "ca.crt"
	caKeyFile  = "ca.key"
	leafDays   = 90
)

type certAuthority struct {
	mu    sync.Mutex
	cert  *x509.Certificate
	key   *rsa.PrivateKey
	cache map[string]*tls.Certificate
}

// loadCA reads the local CA, returns nil when absent
func loadCA(dir string) (*certAuthority, error) {
	certPEM, err := os.ReadFile(filepath.Join(dir, caCertFile))
	if err != nil {
		return nil, err
	}
	keyPEM, err := os.ReadFile(filepath.Join(dir, caKeyFile))
	if err != nil {
		return nil, err
	}

	block, _ := pem.Decode(certPEM)
	if block == nil {
		return nil, fmt.Errorf("bad CA certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}

	kblock, _ := pem.Decode(keyPEM)
	if kblock == nil {
		return nil, fmt.Errorf("bad CA key")
	}
	key, err := x509.ParsePKCS1PrivateKey(kblock.Bytes)
	if err != nil {
		return nil, err
	}

	return &certAuthority{cert: cert, key: key, cache: map[string]*tls.Certificate{}}, nil
}

// genCA writes a CA for leaf signing into dir
// returns the filename to use in the trust store (subject_hash_old)
func genCA(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return "", err
	}

	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "bindhosts proxy CA",
			Organization: []string{"bindhosts"},
		},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
// leaf certs only, no intermediate CA
		MaxPathLen:     0,
		MaxPathLenZero: true,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return "", err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return "", err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	if err := os.WriteFile(filepath.Join(dir, caCertFile), certPEM, 0644); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dir, caKeyFile), keyPEM, 0600); err != nil {
		return "", err
	}

// Android's trust store indexes by subject_hash_old; a wrong name means not installed
	name := subjectHashOld(cert) + ".0"
	if err := os.WriteFile(filepath.Join(dir, name), certPEM, 0644); err != nil {
		return "", err
	}
	return name, nil
}

// subjectHashOld matches openssl x509 -subject_hash_old
func subjectHashOld(cert *x509.Certificate) string {
	sum := md5.Sum(cert.RawSubject)
	return fmt.Sprintf("%08x", binary.LittleEndian.Uint32(sum[:4]))
}

// leafFor signs a leaf for one domain, cached in memory
func (ca *certAuthority) leafFor(sni string) (*tls.Certificate, error) {
	ca.mu.Lock()
	defer ca.mu.Unlock()

	if c, ok := ca.cache[sni]; ok {
		return c, nil
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}

	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: sni},
		DNSNames:              []string{sni},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(0, 0, leafDays),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		return nil, err
	}

	cert := &tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  key,
	}
	ca.cache[sni] = cert
	logf("signed leaf for %s (valid %d days)", sni, leafDays)
	return cert, nil
}

// getCertificate signs only for domains in the allow list
func (ca *certAuthority) getCertificate(allowed func(string) bool) func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	return func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
		sni := strings.ToLower(hello.ServerName)
		if sni == "" {
			return nil, fmt.Errorf("no SNI")
		}
		if !allowed(sni) {
			logf("drop  %s (not in proxy rules)", sni)
			return nil, fmt.Errorf("domain not configured")
		}
		return ca.leafFor(sni)
	}
}
