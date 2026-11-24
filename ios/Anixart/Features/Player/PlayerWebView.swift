import SwiftUI
import WebKit
import UIKit

/// WKWebView для HTML-плееров.
///
/// Ключевой момент: Kodik и подобные плееры проверяют `Referer`/`Origin` и не открываются,
/// если страницу грузить напрямую. Оригинальное приложение подкладывает iframe-обёртку
/// (`assets/player_default.html`) и грузит её с baseURL — так браузер сам подставляет
/// правильный Referer. Здесь делаем то же самое.
struct PlayerWebView: UIViewRepresentable {
    let target: PlaybackTarget
    /// Вызывается, когда HTML-обёртка с плеером загрузилась.
    var onLoaded: (() -> Void)? = nil
    /// Вызывается при ошибке загрузки; текст уже пригоден для показа пользователю.
    var onError: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        #if canImport(WebKit)
        webView.navigationDelegate = context.coordinator
        #endif

        load(into: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        #if canImport(WebKit)
        // SwiftUI пересоздаёт структуру при каждом обновлении, а UIView живёт дольше:
        // координатор должен видеть актуальные замыкания.
        context.coordinator.update(onLoaded: onLoaded, onError: onError)
        #endif
    }

    // MARK: - Координатор
    //
    // Настоящий WKNavigationDelegate есть только в WebKit. В заглушке для Linux-тайпчека
    // (tools/StubSwiftUI) делегатов нет, поэтому блок скрыт за canImport: остальной файл
    // проверяется стендом, а этот код — сборкой под Xcode.
    //
    // Координатор хранит замыкания, а не саму SwiftUI-структуру: протокол делегата
    // не изолирован на главный актор, и обращаться к свойствам `View` из него нельзя.

    #if canImport(WebKit)
    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded, onError: onError)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var onLoaded: (() -> Void)?
        private var onError: ((String) -> Void)?

        init(onLoaded: (() -> Void)?, onError: ((String) -> Void)?) {
            self.onLoaded = onLoaded
            self.onError = onError
        }

        func update(onLoaded: (() -> Void)?, onError: ((String) -> Void)?) {
            self.onLoaded = onLoaded
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError?(Self.message(for: error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError?(Self.message(for: error))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onError?("Процесс веб-плеера завершился. Попробуйте открыть серию в Safari.")
        }

        /// Текст ошибки для пользователя: код `WKError` без описания ничего не говорит.
        private static func message(for error: Error) -> String {
            let nsError = error as NSError
            if !nsError.localizedDescription.isEmpty {
                return "Не удалось загрузить плеер: \(nsError.localizedDescription)"
            }
            return "Не удалось загрузить плеер"
        }
    }
    #endif

    private func load(into webView: WKWebView) {
        switch target.kind {
        case .web(let url):
            let html = PlayerWebView.iframeHTML(src: url.absoluteString)
            webView.loadHTMLString(html, baseURL: target.referer)
        case .youtube(let videoId):
            let html = PlayerWebView.youtubeHTML(videoId: videoId)
            webView.loadHTMLString(html, baseURL: target.referer)
        case .hls(let url):
            webView.load(URLRequest(url: url))
        }
    }

    static func iframeHTML(src: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            <style>
                html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
                iframe { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
            </style>
        </head>
        <body>
            <iframe src="\(src)" allowfullscreen allow="autoplay; fullscreen; encrypted-media"></iframe>
        </body>
        </html>
        """
    }

    static func youtubeHTML(videoId: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            <style>
                html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
                iframe { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
            </style>
        </head>
        <body>
            <iframe src="https://www.youtube.com/embed/\(videoId)?autoplay=1&playsinline=1&rel=0"
                    allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe>
        </body>
        </html>
        """
    }
}
