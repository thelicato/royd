package main

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
)

const target = "https://www.google.com/generate_204"
const untrusted = "https://172.17.0.1:43210/reject"

func TestPublicURLs(t *testing.T) {
	for _, raw := range []string{target, "https://probe.example.org:443/status/204"} {
		if _, err := publicURL(raw); err != nil {
			t.Fatal(raw, err)
		}
	}
	for _, raw := range []string{"", "http://probe.example.org/", "https://127.0.0.1/", "https://[::1]/",
		"https://user:secret@probe.example.org/", "https://probe.example.org/?token=secret", "https://probe.example.org/?",
		"https://probe.example.org/#fragment", "https://probe.example.org:8443/", "https://localhost/",
		"https://probe.example.org/a%0Ab", "https://-probe.example.org/", "https://probe..org/", "https://probe.example.org/\n"} {
		if _, err := publicURL(raw); err == nil {
			t.Fatalf("accepted unsafe/unsupported URL %q", raw)
		}
	}
}

func TestNegativeURLs(t *testing.T) {
	if !negativeURL(untrusted) {
		t.Fatal("rejected private fixture URL")
	}
	for _, raw := range []string{"", "https://172.17.0.1:0/reject", "https://172.17.0.1:65536/reject",
		"http://172.17.0.1:43210/reject", "https://8.8.8.8:43210/reject", "https://172.17.0.1:43210/other",
		"https://user@172.17.0.1:43210/reject", "https://172.17.0.1:43210/reject?token=secret"} {
		if negativeURL(raw) {
			t.Fatalf("accepted invalid negative-control URL %q", raw)
		}
	}
}

func positive() observation {
	return observation{
		UID: 10054, Done: true, URL: target, Untrusted: untrusted, Active: "100", Interface: "eth0",
		Resolvers: []string{"127.0.0.11"}, Callback: 1, Answers: []string{"142.250.1.1", "2001:4860::1"},
		HTTPS: "pass", Status: 204, Cipher: "TLS_AES_256_GCM_SHA384", Peer: strings.Repeat("a", 64),
		Subject: "CN=www.google.com", Issuer: "CN=public issuer", BodySHA: fmt.Sprintf("%x", sha256.Sum256(nil)),
		Rejected: true, Causes: []string{"javax.net.ssl.SSLHandshakeException", "java.security.cert.CertPathValidatorException"},
	}
}

func TestAssessment(t *testing.T) {
	cases := map[string]func(*observation){
		"root":                      func(o *observation) { o.UID = 0 },
		"different-uid":             func(o *observation) { o.UID++ },
		"incomplete":                func(o *observation) { o.Done = false },
		"other-url":                 func(o *observation) { o.URL = "https://other.example.org/" },
		"other-control":             func(o *observation) { o.Untrusted = "https://172.17.0.2:43210/reject" },
		"no-network":                func(o *observation) { o.Active = "null" },
		"no-interface":              func(o *observation) { o.Interface = "eth1" },
		"no-callback":               func(o *observation) { o.Callback = 0 },
		"no-resolver":               func(o *observation) { o.Resolvers = nil },
		"bad-resolver":              func(o *observation) { o.Resolvers = []string{"invalid"} },
		"no-answer":                 func(o *observation) { o.Answers = nil },
		"private-answer":            func(o *observation) { o.Answers = []string{"10.0.0.1"} },
		"ipv6-only":                 func(o *observation) { o.Answers = []string{"2001:4860::1"} },
		"https-failed":              func(o *observation) { o.HTTPS = "fail" },
		"redirect":                  func(o *observation) { o.Status = 302 },
		"empty-cipher":              func(o *observation) { o.Cipher = "" },
		"no-peer":                   func(o *observation) { o.Peer = "" },
		"no-subject":                func(o *observation) { o.Subject = "" },
		"no-issuer":                 func(o *observation) { o.Issuer = "" },
		"oversized":                 func(o *observation) { o.BodyBytes = 65537 },
		"wrong-body":                func(o *observation) { o.BodySHA = strings.Repeat("0", 64) },
		"accepted-self-signed":      func(o *observation) { o.Rejected = false },
		"timeout-not-trust":         func(o *observation) { o.Causes = []string{"java.net.SocketTimeoutException"} },
		"handshake-not-certificate": func(o *observation) { o.Causes = []string{"javax.net.ssl.SSLHandshakeException"} },
		"probe-error":               func(o *observation) { o.ProbeError = "failure" },
	}
	encode := func(o observation) []byte {
		raw, err := json.Marshal(o)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	if _, pass := assess(encode(positive()), target, untrusted, 204, 10054); !pass {
		t.Fatal("rejected complete evidence")
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			o := positive()
			mutate(&o)
			if _, pass := assess(encode(o), target, untrusted, 204, 10054); pass {
				t.Fatal("accepted invalid evidence")
			}
		})
	}
	for _, raw := range []string{"", "{}", "null", "not-json"} {
		if _, pass := assess([]byte(raw), target, untrusted, 204, 10054); pass {
			t.Fatal("accepted missing evidence")
		}
	}
	for _, status := range []int{0, 199, 300} {
		if _, pass := assess(encode(positive()), target, untrusted, status, 10054); pass {
			t.Fatal("accepted invalid status")
		}
	}
}

func TestNegativeCertificate(t *testing.T) {
	ip := net.ParseIP("172.17.0.1")
	first, err := certificate(ip)
	if err != nil {
		t.Fatal(err)
	}
	second, err := certificate(ip)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(first.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if string(first.Certificate[0]) == string(second.Certificate[0]) {
		t.Fatal("certificate must be ephemeral")
	}
	if err := cert.VerifyHostname(ip.String()); err != nil {
		t.Fatal("negative control must have matching IP identity", err)
	}
	_, err = cert.Verify(x509.VerifyOptions{Roots: x509.NewCertPool(), DNSName: ip.String()})
	var unknown x509.UnknownAuthorityError
	if !errors.As(err, &unknown) {
		t.Fatalf("expected unknown authority, got %v", err)
	}
	// Test the fixture's validity only, never add it to Android's trust store.
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	if _, err := cert.Verify(x509.VerifyOptions{Roots: roots, DNSName: ip.String()}); err != nil {
		t.Fatal(err)
	}
}
