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

func TestResultIdentity(t *testing.T) {
	for _, test := range []struct {
		raw, name string
		pass      bool
	}{
		{`{"result_name":"round-001.json"}`, "round-001.json", true},
		{`{"result_name":"round-100.json"}`, "round-100.json", true},
		{`{"result_name":"round-001.json"}`, "round-002.json", false},
		{`{}`, "round-001.json", false},
		{`{`, "round-001.json", false},
		{`{"result_name":1}`, "round-001.json", false},
		{`{"result_name":"../result.json"}`, "../result.json", false},
		{`{"result_name":"round-1.json"}`, "round-1.json", false},
		{`{"result_name":"round-001.json\n"}`, "round-001.json\n", false},
	} {
		if got := resultIdentity([]byte(test.raw), test.name); got != test.pass {
			t.Fatalf("result identity (%q, %q) = %v", test.raw, test.name, got)
		}
	}
}

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

func positiveWeb(t *testing.T) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(positive())
	var o map[string]any
	if err := json.Unmarshal(raw, &o); err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]any{
		"webview_url": "https://example.com/", "webview_untrusted_url": untrusted,
		"webview_provider_package": "com.android.webview", "webview_provider_version": "test-version",
		"webview_user_agent":          "Mozilla/5.0 (Linux; Android 15; test; wv) AppleWebKit/537.36",
		"webview_certificate_subject": "CN=example.com", "webview_certificate_issuer": "CN=issuer",
		"webview_committed": true, "webview_visual_state": true,
		"webview_untrusted_rejected": true, "webview_untrusted_cancelled": true,
		"webview_untrusted_has_authority_error": true, "webview_untrusted_primary_error": 3,
		"webview_untrusted_error_url": untrusted,
		"webview_dom":                 map[string]any{"url": "https://example.com/", "title": "Example Domain", "heading": "Example Domain", "secure": true, "ready": "complete"},
	} {
		o[key] = value
	}
	return o
}

func TestWebViewAssessment(t *testing.T) {
	check := func(o map[string]any) bool {
		raw, _ := json.Marshal(o)
		_, pass := assessWebView(raw, target, untrusted, 204, 10054, "https://example.com/", "Example Domain")
		return pass
	}
	if !check(positiveWeb(t)) {
		t.Fatal("rejected complete combined evidence")
	}
	for key, value := range map[string]any{
		"done": false, "uid": 0, "public_https": "fail", "untrusted_rejected": false,
		"webview_url": "https://other.example/", "webview_untrusted_url": target,
		"webview_provider_package": "", "webview_provider_version": "", "webview_user_agent": "not a WebView",
		"webview_certificate_subject": "", "webview_certificate_issuer": "",
		"webview_committed": false, "webview_visual_state": false,
		"webview_error": "timeout", "webview_public_ssl_error": "bad certificate",
		"webview_control_error":      "transport failure",
		"webview_untrusted_rejected": false, "webview_untrusted_cancelled": false,
		"webview_untrusted_has_authority_error": false, "webview_untrusted_primary_error": 2,
		"webview_untrusted_error_url": target,
	} {
		t.Run(key, func(t *testing.T) {
			o := positiveWeb(t)
			o[key] = value
			if check(o) {
				t.Fatal("accepted invalid evidence")
			}
		})
	}
	for key, value := range map[string]any{"url": target, "title": "Wrong", "heading": "Wrong", "secure": false, "ready": "loading"} {
		t.Run("dom-"+key, func(t *testing.T) {
			o := positiveWeb(t)
			o["webview_dom"].(map[string]any)[key] = value
			if check(o) {
				t.Fatal("accepted invalid DOM")
			}
		})
	}
	for key := range positiveWeb(t) {
		if strings.HasPrefix(key, "webview_") {
			o := positiveWeb(t)
			delete(o, key)
			if check(o) {
				t.Fatalf("accepted missing %s", key)
			}
		}
	}
	// The original public target changed its markup. Retain strict document
	// identity rather than accepting a title-only page with no expected h1.
	oWithoutHeading := positiveWeb(t)
	oWithoutHeading["webview_dom"].(map[string]any)["heading"] = ""
	rawWithoutHeading, _ := json.Marshal(oWithoutHeading)
	statusesWithoutHeading, passWithoutHeading := assessWebView(rawWithoutHeading, target, untrusted, 204, 10054,
		"https://example.com/", "Example Domain")
	if passWithoutHeading || !strings.Contains(statusesWithoutHeading, "WEBVIEW_DOCUMENT_STATUS=fail\n") ||
		!strings.Contains(statusesWithoutHeading, "WEBVIEW_UNTRUSTED_CERT_STATUS=pass\n") {
		t.Fatal("accepted changed document or lost independent certificate rejection", statusesWithoutHeading)
	}
	for _, title := range []string{"", "title\ninjected=value", "title\r", strings.Repeat("x", 121), "<script>"} {
		if webTarget("https://example.com/", title) {
			t.Fatalf("accepted title %q", title)
		}
	}
	if webTarget("http://example.com/", "Example Domain") {
		t.Fatal("accepted HTTP WebView target")
	}
	o := positiveWeb(t)
	o["webview_control_error"] = "transport failure"
	raw, _ := json.Marshal(o)
	statuses, pass := assessWebView(raw, target, untrusted, 204, 10054, "https://example.com/", "Example Domain")
	if pass || !strings.Contains(statuses, "WEBVIEW_DOCUMENT_STATUS=pass\n") ||
		!strings.Contains(statuses, "WEBVIEW_UNTRUSTED_CERT_STATUS=fail\n") {
		t.Fatal("lost independent document evidence after control failure", statuses)
	}
}
