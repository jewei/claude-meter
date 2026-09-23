import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation
import SwiftUI
import WebKit

struct ClaudeWebResetObservation {
    let organizationID: String
    let resets: ClaudeLimitResets
    let observedAt: Date
}

@MainActor
final class ClaudeWebResetSession: NSObject, WKUIDelegate {
    enum FetchError: Error, Equatable {
        case signInRequired
        case requestFailed
        case invalidResponse
    }

    private static let usageURL = URL(string: "https://claude.ai/settings/usage")!
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.uiDelegate = self
        return view
    }()

    func showSignInPage() {
        webView.load(URLRequest(url: Self.usageURL))
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let claudeRecords = records.filter {
            $0.displayName == "claude.ai" || $0.displayName.hasSuffix(".claude.ai")
                || $0.displayName == "anthropic.com"
                || $0.displayName.hasSuffix(".anthropic.com")
        }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: claudeRecords) {
                continuation.resume()
            }
        }
        webView.loadHTMLString("", baseURL: nil)
    }

    func fetch() async throws -> [ClaudeWebResetObservation] {
        if webView.url?.host != "claude.ai" {
            showSignInPage()
            for _ in 0..<150 {
                try await Task.sleep(for: .milliseconds(100))
                if !webView.isLoading, webView.url != nil { break }
            }
        }
        guard webView.url?.host == "claude.ai" else { throw FetchError.signInRequired }

        let result = try await webView.callAsyncJavaScript(
            ClaudeWebResetPayload.readScript,
            arguments: [:],
            in: nil,
            contentWorld: .page)
        guard let json = result as? String,
            let response = try? JSONDecoder().decode(WebResult.self, from: Data(json.utf8))
        else { throw FetchError.invalidResponse }
        if response.kind == "signInRequired" { throw FetchError.signInRequired }
        guard response.kind == "success" else { throw FetchError.requestFailed }
        let now = Date()
        return (response.records ?? []).compactMap { record in
            guard let resets = ClaudeWebResetPayload.parse(Data(record.resetJSON.utf8))
            else { return nil }
            return ClaudeWebResetObservation(
                organizationID: record.organizationID,
                resets: resets,
                observedAt: now)
        }
    }

    private struct WebResult: Decodable {
        let kind: String
        let records: [WebRecord]?
    }

    private struct WebRecord: Decodable {
        let organizationID: String
        let resetJSON: String
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Claude sign in"
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows[ObjectIdentifier(popup)] = window
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindows.removeValue(forKey: ObjectIdentifier(webView))?.close()
    }
}

struct ClaudeWebSignInView: View {
    let session: ClaudeWebResetSession
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Claude")
                    .font(PFont.display(17, .semibold))
                Spacer()
                Button("Done") {
                    done()
                    dismiss()
                }
            }
            .padding(14)
            Divider()
            ClaudeWebView(session: session)
        }
        .frame(minWidth: 860, minHeight: 640)
        .onAppear { session.showSignInPage() }
    }
}

private struct ClaudeWebView: NSViewRepresentable {
    let session: ClaudeWebResetSession

    func makeNSView(context _: Context) -> WKWebView { session.webView }
    func updateNSView(_: WKWebView, context _: Context) {}
}
