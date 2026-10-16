package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPProof(t *testing.T) {
	const ua = "Mozilla/5.0 (Linux; Android 15; test; wv) Chrome/128"
	cases := []struct {
		name, method, path, agent string
		prime                     bool
		status                    int
		proof                     bool
	}{
		{"page", "GET", "/page/nonce", ua, false, 200, false},
		{"callback", "GET", "/loaded/nonce", ua, true, 204, true},
		{"no-page", "GET", "/loaded/nonce", ua, false, 403, false},
		{"wrong-nonce", "GET", "/loaded/other", ua, true, 404, false},
		{"shell-callback", "GET", "/loaded/nonce", "shell", true, 403, false},
		{"shell-page", "GET", "/page/nonce", "shell", false, 200, false},
		{"wrong-method", "POST", "/loaded/nonce", ua, true, 405, false},
		{"unknown", "GET", "/favicon.ico", ua, true, 404, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var events bytes.Buffer
			handler := probeHandler("nonce", &events)
			if tc.prime {
				request := httptest.NewRequest("GET", "/page/nonce", nil)
				request.Header.Set("User-Agent", ua)
				handler.ServeHTTP(httptest.NewRecorder(), request)
			}
			request := httptest.NewRequest(tc.method, tc.path, nil)
			request.Header.Set("User-Agent", tc.agent)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != tc.status || strings.Contains(events.String(), "WEBVIEW_CALLBACK=pass") != tc.proof {
				t.Fatalf("status=%d events=%q", response.Code, events.String())
			}
			if response.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("cache must be disabled")
			}
			if tc.name == "page" && !strings.Contains(response.Body.String(), "fetch('/loaded/nonce')") {
				t.Fatal("the page must execute the nonce callback")
			}
		})
	}
}

func TestShellCannotPrimeProof(t *testing.T) {
	var events bytes.Buffer
	handler := probeHandler("nonce", &events)
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/page/nonce", nil))
	request := httptest.NewRequest("GET", "/loaded/nonce", nil)
	request.Header.Set("User-Agent", "(Android 15; wv)")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden || strings.Contains(events.String(), "WEBVIEW_CALLBACK=pass") {
		t.Fatal("a shell request must not prime an application proof")
	}
}
