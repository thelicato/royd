package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func publicURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	label := regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`)
	if err != nil || u.Scheme != "https" || u.Opaque != "" || u.User != nil ||
		u.RawQuery != "" || u.ForceQuery || u.Fragment != "" ||
		(u.Port() != "" && u.Port() != "443") || net.ParseIP(u.Hostname()) != nil ||
		!strings.Contains(u.Hostname(), ".") || len(u.Hostname()) > 253 ||
		!regexp.MustCompile(`^/[a-zA-Z0-9/_.,-]*$`).MatchString(u.EscapedPath()) {
		return nil, fmt.Errorf("public HTTPS DNS name, port 443 and plain absolute path required")
	}
	for _, part := range strings.Split(u.Hostname(), ".") {
		if !label.MatchString(part) {
			return nil, fmt.Errorf("invalid DNS label")
		}
	}
	return u, nil
}

type observation struct {
	UID        int      `json:"uid"`
	Done       bool     `json:"done"`
	URL        string   `json:"url"`
	Untrusted  string   `json:"untrusted_url"`
	Active     string   `json:"active_network"`
	Interface  string   `json:"active_interface"`
	Resolvers  []string `json:"configured_dns"`
	Callback   int      `json:"default_callback_available"`
	Answers    []string `json:"dns_answers"`
	HTTPS      string   `json:"public_https"`
	Status     int      `json:"http_status"`
	Cipher     string   `json:"cipher_suite"`
	Peer       string   `json:"peer_sha256"`
	Subject    string   `json:"peer_subject"`
	Issuer     string   `json:"peer_issuer"`
	BodyBytes  int      `json:"body_bytes"`
	BodySHA    string   `json:"body_sha256"`
	Rejected   bool     `json:"untrusted_rejected"`
	Causes     []string `json:"untrusted_causes"`
	ProbeError string   `json:"probe_error"`
}

func negativeURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	ip := net.ParseIP(u.Hostname())
	port, err := strconv.Atoi(u.Port())
	return err == nil && port > 0 && port <= 65535 && ip.To4() != nil && ip.IsPrivate() &&
		u.Scheme == "https" && u.User == nil && u.Path == "/reject" && u.RawPath == "" &&
		u.RawQuery == "" && !u.ForceQuery && u.Fragment == ""
}

func assess(raw []byte, target, untrusted string, expectedStatus, expectedUID int) (string, bool) {
	var o observation
	_, err := publicURL(target)
	if err != nil || !negativeURL(untrusted) || expectedStatus < 200 || expectedStatus > 299 || json.Unmarshal(raw, &o) != nil ||
		!o.Done || expectedUID < 10000 || o.UID != expectedUID || o.URL != target || o.Untrusted != untrusted || o.ProbeError != "" {
		return "OBSERVATION_STATUS=fail\n", false
	}
	id, err := strconv.ParseUint(o.Active, 10, 32)
	framework := err == nil && id > 0 && o.Interface == "eth0" && o.Callback > 0 && len(o.Resolvers) > 0
	for _, address := range o.Resolvers {
		if net.ParseIP(address) == nil {
			framework = false
		}
	}
	dns := false
	for _, address := range o.Answers {
		ip := net.ParseIP(address)
		if ip != nil && ip.To4() != nil && ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() {
			dns = true
		}
	}
	hex := regexp.MustCompile(`^[0-9a-f]{64}$`)
	https := o.HTTPS == "pass" && o.Status == expectedStatus && strings.HasPrefix(o.Cipher, "TLS_") &&
		hex.MatchString(o.Peer) && o.Subject != "" && o.Issuer != "" &&
		o.BodyBytes >= 0 && o.BodyBytes <= 65536 && hex.MatchString(o.BodySHA)
	if expectedStatus == 204 {
		https = https && o.BodyBytes == 0 && o.BodySHA == fmt.Sprintf("%x", sha256.Sum256(nil))
	}
	certificate := false
	for _, cause := range o.Causes {
		if cause == "java.security.cert.CertificateException" || cause == "java.security.cert.CertPathValidatorException" {
			certificate = true
		}
	}
	rejected := o.Rejected && certificate && len(o.Causes) > 0 && o.Causes[0] == "javax.net.ssl.SSLHandshakeException"
	status := func(pass bool) string {
		if pass {
			return "pass"
		}
		return "fail"
	}
	return fmt.Sprintf("OBSERVATION_STATUS=pass\nPUBLIC_DNS_STATUS=%s\nPUBLIC_HTTPS_STATUS=%s\nUNTRUSTED_CERT_STATUS=%s\nFRAMEWORK_NETWORK_STATUS=%s\n",
		status(dns), status(https), status(rejected), status(framework)), dns && https && rejected && framework
}

// Ephemeral self-signed negative control. Its key never leaves process memory.
func certificate(ip net.IP) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	cert := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "royd untrusted TLS control"},
		NotBefore: time.Now().Add(-5 * time.Minute), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{ip}, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, err
}

func main() {
	listen := flag.String("listen", "", "owned private Docker bridge IPv4 and port 0")
	check := flag.String("check-url", "", "validate a public HTTPS URL without network access")
	result := flag.String("result", "", "assess app JSON without a listener")
	target := flag.String("url", "", "expected public HTTPS URL")
	untrusted := flag.String("untrusted", "", "expected negative-control URL")
	expectedStatus := flag.Int("status", 204, "expected public HTTP status")
	expectedUID := flag.Int("uid", 0, "observed ordinary application UID")
	flag.Parse()
	if *check != "" {
		u, err := publicURL(*check)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Println("PUBLIC_HOST=" + u.Hostname())
		return
	}
	if *result != "" {
		raw, err := os.ReadFile(*result)
		if err != nil {
			log.Fatal(err)
		}
		text, pass := assess(raw, *target, *untrusted, *expectedStatus, *expectedUID)
		fmt.Print(text)
		if !pass {
			os.Exit(1)
		}
		return
	}
	host, port, err := net.SplitHostPort(*listen)
	ip := net.ParseIP(host)
	if err != nil || ip.To4() == nil || !ip.IsPrivate() || port != "0" {
		log.Fatal("private bridge IPv4 and ephemeral port required")
	}
	cert, err := certificate(ip)
	if err != nil {
		log.Fatal(err)
	}
	listener, err := net.Listen("tcp4", *listen)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("UNTRUSTED_URL=https://%s/reject\nCERT_SHA256=%x\n", listener.Addr(), sha256.Sum256(cert.Certificate[0]))
	server := &http.Server{
		ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			fmt.Println("UNTRUSTED_HTTP_REQUEST=unexpected")
			w.WriteHeader(http.StatusNoContent)
		}),
	}
	log.Fatal(server.ServeTLS(listener, "", ""))
}
