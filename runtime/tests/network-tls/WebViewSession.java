package org.royd.tlsprobe;

import android.app.Activity;
import android.net.http.SslError;
import android.os.Handler;
import android.os.Looper;
import android.webkit.SslErrorHandler;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import org.json.JSONArray;
import org.json.JSONObject;

/** Optional ordinary-UID browser check. No native JavaScript bridge or trust override. */
final class WebViewSession {
    private final Activity activity;
    private final String target;
    private final String untrusted;
    private final JSONObject result;
    private final Runnable publish;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private WebView page;
    private WebView control;
    private boolean finished;
    private boolean committed;
    private boolean evaluating;
    private boolean cancelled;

    WebViewSession(Activity activity, String target, String untrusted, JSONObject result, Runnable publish) {
        this.activity = activity;
        this.target = target;
        this.untrusted = untrusted;
        this.result = result;
        this.publish = publish;
    }

    static boolean expectedRejection(String expected, String observed, int primary, boolean untrusted) {
        return expected.equals(observed) && primary == SslError.SSL_UNTRUSTED && untrusted;
    }

    private void put(String key, Object value) {
        try { result.put(key, value); } catch (Exception error) { throw new IllegalStateException(error); }
    }

    private void finish(String error) {
        if (finished) return;
        finished = true;
        if (error != null) put(control == null ? "webview_error" : "webview_control_error", error);
        if (error != null && page != null) page.stopLoading();
        if (control != null) { control.stopLoading(); control.destroy(); }
        // Keep the real public page visible for the retained screenshot.
        put("done", true);
        publish.run();
    }

    void start() {
        put("webview_url", target);
        put("webview_untrusted_url", untrusted);
        put("done", false);
        page = new WebView(activity);
        android.content.pm.PackageInfo provider = WebView.getCurrentWebViewPackage();
        put("webview_provider_package", provider == null ? "" : provider.packageName);
        put("webview_provider_version", provider == null ? "" : provider.versionName);
        put("webview_user_agent", page.getSettings().getUserAgentString());
        page.getSettings().setJavaScriptEnabled(true);
        page.getSettings().setAllowFileAccess(false);
        page.getSettings().setAllowContentAccess(false);
        page.getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        page.getSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
        page.setWebViewClient(new WebViewClient() {
            private boolean completed;
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if (request.isForMainFrame() && !target.equals(request.getUrl().toString())) {
                    finish("unexpected public navigation: " + request.getUrl());
                    return true;
                }
                return false;
            }
            @Override public void onPageStarted(WebView view, String url, android.graphics.Bitmap icon) {
                if (!target.equals(url)) finish("unexpected public page: " + url);
            }
            @Override public void onReceivedSslError(WebView view, SslErrorHandler ssl, SslError error) {
                if (!finished) put("webview_public_ssl_error", error.toString());
                ssl.cancel();
                finish("public page certificate rejected");
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) finish("public load error: " + error.getErrorCode());
            }
            @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame()) finish("public HTTP error: " + response.getStatusCode());
            }
            @Override public void onPageCommitVisible(WebView view, String url) {
                if (target.equals(url)) committed = true;
                inspectDocument(view, url);
            }
            @Override public void onPageFinished(WebView view, String url) {
                completed = true;
                inspectDocument(view, url);
            }
            private void inspectDocument(WebView view, String url) {
                if (finished || evaluating || !committed || !completed) return;
                if (!target.equals(url) || view.getCertificate() == null) {
                    finish("public page has no matching committed TLS document");
                    return;
                }
                evaluating = true;
                put("webview_certificate_subject", view.getCertificate().getIssuedTo().getDName());
                put("webview_certificate_issuer", view.getCertificate().getIssuedBy().getDName());
                view.postVisualStateCallback(1, new WebView.VisualStateCallback() {
                    @Override public void onComplete(long requestId) {
                        if (finished) return;
                        put("webview_visual_state", true);
                        view.evaluateJavascript("JSON.stringify({url:location.href,title:document.title.slice(0,512),"
                                + "heading:(document.querySelector('h1')?.textContent||'').trim().slice(0,512),"
                                + "secure:window.isSecureContext,ready:document.readyState})", raw -> {
                            if (finished) return;
                            try {
                                if (raw == null || raw.length() > 65536) throw new IllegalStateException("invalid DOM result");
                                JSONObject dom = new JSONObject(new JSONArray("[" + raw + "]").getString(0));
                                put("webview_dom", dom);
                                put("webview_committed", committed);
                                startControl();
                            } catch (Exception error) { finish("DOM evaluation failed: " + error); }
                        });
                    }
                });
            }
        });
        activity.setContentView(page);
        handler.postDelayed(() -> finish("WebView probe timed out"), 40000);
        page.loadUrl(target);
    }

    private void startControl() {
        if (finished || control != null) return;
        // Separate off-screen instance keeps the public proof visible. The
        // control needs a TLS decision, not a rendered error page.
        control = new WebView(activity);
        control.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if (request.isForMainFrame() && !untrusted.equals(request.getUrl().toString())) {
                    finish("unexpected control navigation");
                    return true;
                }
                return false;
            }
            @Override public void onReceivedSslError(WebView view, SslErrorHandler ssl, SslError error) {
                cancelled = true;
                ssl.cancel();
                put("webview_untrusted_primary_error", error.getPrimaryError());
                put("webview_untrusted_has_authority_error", error.hasError(SslError.SSL_UNTRUSTED));
                put("webview_untrusted_cancelled", true);
                put("webview_untrusted_rejected", expectedRejection(untrusted, error.getUrl(),
                        error.getPrimaryError(), error.hasError(SslError.SSL_UNTRUSTED)));
                put("webview_untrusted_error_url", error.getUrl());
                handler.postDelayed(() -> finish(null), 1000);
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame() && !cancelled) finish("control transport error: " + error.getErrorCode());
            }
            @Override public void onPageFinished(WebView view, String url) {
                if (!cancelled) finish("control finished without a certificate rejection");
            }
        });
        control.loadUrl(untrusted);
    }
}
