import SwiftUI
import WebKit

// ============================================================
// GayChou 壳 App（WKWebView）
// - 打开 https://raw.gaychou.top
// - Cookie / localStorage 持久化（登录状态共用、保留）
// - 支持返回手势 / 下拉刷新 / 顶部加载进度条
// - 外链（支付宝/微信支付、tel: 等）交给系统 App 打开
// ============================================================

let kStartURL = "https://raw.gaychou.top"

@main
struct GayChouApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // 深色模式交给网站自己决定（网站有完整明暗主题，App 不强制）
                .preferredColorScheme(nil)
        }
    }
}

struct ContentView: View {
    @State private var refreshable = false
    var body: some View {
        WebView()
            .ignoresSafeArea(edges: .bottom)
    }
}

struct WebView: UIViewRepresentable {
    // 全 App 共用一个 ProcessPool，保证 Cookie 在会话间共享
    static let sharedProcessPool = WKProcessPool()

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = Self.sharedProcessPool
        cfg.websiteDataStore = WKWebsiteDataStore.default() // 持久化存储，登录状态保留
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let pref = WKWebpagePreferences()
        pref.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = pref

        // 用户代理：带上 GCApp 标记，网站可据此识别原生壳
        cfg.applicationNameForUserAgent = "GayChouApp/1.0"

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .automatic
        // 下拉刷新
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.didPullToRefresh), for: .valueChanged)
        wv.scrollView.addSubview(refresh)
        context.coordinator.refreshControl = refresh
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: kStartURL)!))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var refreshControl: UIRefreshControl?
        var progObservation: NSKeyValueObservation?
        weak var progressBar: UIProgressView?

        @objc func didPullToRefresh() {
            guard let wv = refreshControl?.superview as? WKWebView else { return }
            wv.reload()
        }

        func attachProgress(to wv: WKWebView) {
            guard progressBar == nil else { return }
            let bar = UIProgressView(progressViewStyle: .default)
            bar.tintColor = UIColor(red: 0.24, green: 0.48, blue: 1.0, alpha: 1.0)
            bar.translatesAutoresizingMaskIntoConstraints = false
            wv.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: wv.topAnchor, constant: 0),
                bar.leadingAnchor.constraint(equalTo: wv.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: wv.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: 2)
            ])
            progressBar = bar
            progObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] webview, _ in
                let p = Float(webview.estimatedProgress)
                self?.progressBar?.setProgress(p, animated: true)
                self?.progressBar?.isHidden = p >= 1.0
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            attachProgress(to: webView)
            progressBar?.isHidden = false
            progressBar?.setProgress(0.05, animated: false)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            progressBar?.setProgress(1.0, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.progressBar?.isHidden = true
                self?.progressBar?.setProgress(0, animated: false)
            }
            if let rc = refreshControl, rc.isRefreshing { rc.endRefreshing() }
        }

        // 外链（支付宝/微信支付跳转、tel: 等）交给系统打开
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            let scheme = url.scheme?.lowercased() ?? ""

            // 支付/系统类 scheme：交给系统 App
            if ["alipay", "alipays", "weixin", "weixinulink", "mqq", "tel", "mailto", "sms", "itms-apps"].contains(scheme) {
                // open 回调没反应时（例如未装对应 App），回退到网页继续加载
                UIApplication.shared.open(url, options: [:]) { opened in
                    if !opened {
                        DispatchQueue.main.async { webView.load(URLRequest(url: url)) }
                    }
                }
                decisionHandler(.cancel)
                return
            }

            // App Store / 系统 App 的 https 跳转也交给系统（如 itms-services）
            if url.host?.hasSuffix("apple.com") == true {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        // 页面报错：主文档加载失败时提示 + 自动重试一次
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if let rc = refreshControl, rc.isRefreshing { rc.endRefreshing() }
            handleLoadError(error, webView: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if let rc = refreshControl, rc.isRefreshing { rc.endRefreshing() }
            handleLoadError(error, webView: webView)
        }

        private func handleLoadError(_ error: Error, webView: WKWebView) {
            let nsErr = error as NSError
            guard nsErr.code != NSURLErrorCancelled else { return }
            // 只重试一次（用 URL 标记防死循环）
            let key = "retry:" + (webView.url?.absoluteString ?? "")
            if webView.backForwardList.currentItem != nil,
               objc_getAssociatedObject(webView, &key) == nil {
                objc_setAssociatedObject(webView, &key, true, .OBJC_ASSOCIATION_RETAIN)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { webView.reload() }
            }
        }

        // target=_blank 的链接（新窗口）：在当前 WebView 打开，而不是没反应
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }

        // window.alert / confirm：不实现的话 JS alert 会完全没反应，收银台的确认框全靠它
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
            present(ac, from: webView)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            present(ac, from: webView)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let ac = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            ac.addTextField { $0.text = defaultText }
            ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(ac.textFields?.first?.text) })
            ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            present(ac, from: webView)
        }

        private func present(_ ac: UIAlertController, from webView: WKWebView) {
            var base = webView.parentViewController
            while let p = base?.presentedViewController { base = p }
            base?.present(ac, animated: true)
        }
    }
}

extension UIView {
    var parentViewController: UIViewController? {
        var r: UIResponder? = self
        while let n = r?.next {
            if let vc = n as? UIViewController { return vc }
            r = n
        }
        return nil
    }
}
