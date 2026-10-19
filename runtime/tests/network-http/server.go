package main

import (
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// This optional host test fixture serves only an in-memory nonce page.
// It is not part of the Android image or the normal runtime path.
func probeHandler(nonce string, events io.Writer) http.Handler {
	var mu sync.Mutex
	pageSeen := false
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		fmt.Fprintf(events, "request method=%q path=%q query=%q remote=%q user_agent=%q\n", r.Method, r.URL.Path, r.URL.RawQuery, r.RemoteAddr, r.UserAgent())
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		webview := strings.Contains(r.UserAgent(), "; wv)") && strings.Contains(r.UserAgent(), "Android")
		switch r.URL.Path {
		case "/page/" + nonce:
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			if webview {
				pageSeen = true
				fmt.Fprintln(events, "WEBVIEW_PAGE=pass")
			}
			fmt.Fprintf(w, "<!doctype html><meta name=viewport content='width=device-width'><title>royd HTTP proof</title><h1>royd HTTP proof</h1><p>%s</p><script>fetch('/loaded/%s').then(function(){document.body.append(' JavaScript callback completed');});</script>", nonce, nonce)
		case "/loaded/" + nonce:
			if !pageSeen || !webview {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			fmt.Fprintln(events, "WEBVIEW_CALLBACK=pass")
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	})
}

func main() {
	listen := flag.String("listen", "", "literal local Docker bridge IPv4 address and port 0")
	flag.Parse()
	host, port, err := net.SplitHostPort(*listen)
	ip := net.ParseIP(host)
	if err != nil || ip == nil || ip.To4() == nil || !ip.IsPrivate() || port != "0" {
		log.Fatal("a specific local bridge IPv4 address and ephemeral port are required")
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		log.Fatal(err)
	}
	nonce := hex.EncodeToString(random[:])
	listener, err := net.Listen("tcp4", *listen)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("URL=http://%s/page/%s\n", listener.Addr(), nonce)
	server := &http.Server{
		Handler:           probeHandler(nonce, os.Stdout),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       10 * time.Second,
	}
	log.Fatal(server.Serve(listener))
}
