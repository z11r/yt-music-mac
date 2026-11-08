import AppKit
import CryptoKit
import Observation
import WebKit
import YouTubeMusic

enum SessionPolicy {
    static func allowsLoginNavigation(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["youtube.com", "google.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func musicCookies(_ cookies: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
        cookies.filter {
            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (domain == "youtube.com" || domain == "music.youtube.com") && $0.isSecure &&
                ($0.expiresDate.map { $0 > now } ?? true) &&
                !$0.value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ";" })
        }.sorted { $0.name < $1.name }
    }
}

/// Uses only this app's WebKit store. Credentials never enter preferences or logs.
@MainActor @Observable
final class WebSession: NSObject {
    let dataStore: WKWebsiteDataStore
    let credentials: MusicSessionStore
    private(set) var isSignedIn = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var loginWebView: WKWebView?
    var onAccountChanged: ((_ replacedAccount: Bool) -> Void)?
    var onSignInCompleted: (() -> Void)?
    var onAccountConfirmed: ((String) -> Void)?

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var accountKey: String?
    @ObservationIgnored private var isClearing = false
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var currentConfiguration: MusicClientConfiguration?
    @ObservationIgnored private var authUser = 0
    @ObservationIgnored private var delegatedSessionID: String?
    @ObservationIgnored private var loginAttempt = false
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private let loginMedia = LoginMediaSuspensionGate()
    @ObservationIgnored private var loginMediaTarget: WKLoginMediaSuspensionTarget?

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init(dataStore: WKWebsiteDataStore, credentials: MusicSessionStore, preferences: UserDefaults) {
        self.dataStore = dataStore
        self.credentials = credentials
        self.preferences = preferences
        super.init()
        dataStore.httpCookieStore.add(self)
    }

    func suspendOwnership() {
        guard !isSuspended else { return }
        isSuspended = true
        closeLogin()
        dataStore.httpCookieStore.remove(self)
    }

    var confirmedAccountKey: String? { isSignedIn && !isSuspended && !isClearing ? accountKey : nil }

    func resumeOwnership() {
        guard isSuspended else { return }
        isSuspended = false
        dataStore.httpCookieStore.add(self)
        if isSignedIn, let accountKey { onAccountConfirmed?(accountKey) }
    }

    func restore(using loadSessionPage: @MainActor () -> Bool) async {
        guard !isSuspended else { return }
        let operation = epoch
        if preferences.bool(forKey: "sessionRestoreBlocked") {
            isClearing = true
            await clearWebsiteData()
            isClearing = false
            return
        }
        let cookies = SessionPolicy.musicCookies(await dataStore.httpCookieStore.allCookies())
        guard operation == epoch, !isSuspended, !isClearing, !preferences.bool(forKey: "sessionRestoreBlocked") else { return }
        guard cookies.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else { return }
        // Reuse the playback view to establish the selected profile. A separate
        // account view is needed only when the user opens the sign-in interface.
        isRestoringSession = true
        isWorking = true
        errorMessage = nil
        if !loadSessionPage() { sessionRestoreFailed() }
    }

    func sessionRestoreFailed() {
        guard !isSuspended, isRestoringSession, !isClearing else { return }
        isRestoringSession = false
        epoch = UUID()
        refreshTask?.cancel()
        isWorking = false
        errorMessage = AppLocalization.text("Could not restore the YouTube Music session. Open Account to sign in again.")
    }

    func openLogin() {
        guard !isSuspended, !isClearing else { return }
        // Repeated clicks cannot supersede a pending suspension or create more views.
        if let target = loginMediaTarget, !loginMedia.isReady(target) { return }
        guard loginWebView != nil || loginMedia.canCreateView else {
            reportLoginMediaBlocked(); return
        }
        epoch = UUID()
        refreshTask?.cancel()
        isRestoringSession = false
        errorMessage = nil
        isWorking = true
        loginAttempt = true
        if let view = loginWebView, let target = loginMediaTarget, loginMedia.isReady(target) {
            view.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        ProfileStoreLeaseRetention.attachView(view, from: dataStore)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        let target = WKLoginMediaSuspensionTarget(view)
        loginWebView = view; loginMediaTarget = target
        let operation = epoch
        loginMedia.begin(target, onReady: { [weak self, weak view, weak target] in
            guard let self, let view, let target, self.epoch == operation,
                  self.acceptsLoginView(view), self.loginMedia.isReady(target) else { return }
            view.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        }, onBlocked: { [weak self, weak target] in
            guard let self, let target, self.epoch == operation, self.loginMediaTarget === target,
                  !self.isSuspended, !self.isClearing else { return }
            self.reportLoginMediaBlocked()
        })
    }

    private func reportLoginMediaBlocked() {
        isWorking = false
        errorMessage = LoginMediaText.text("Could not prepare the account page safely. Close Account and try again.")
    }

    private func acceptsLoginView(_ view: WKWebView) -> Bool {
        guard !isSuspended, !isClearing, loginWebView === view, let target = loginMediaTarget else { return false }
        return loginMedia.isReady(target)
    }

    func closeLogin() {
        epoch = UUID()
        isRestoringSession = false
        refreshTask?.cancel()
        loginMedia.revoke()
        loginWebView?.stopLoading()
        loginWebView?.navigationDelegate = nil
        loginWebView?.uiDelegate = nil
        loginWebView = nil; loginMediaTarget = nil
        isWorking = false
        loginAttempt = false
    }

    @discardableResult
    func synchronize(from webView: WKWebView) async -> Bool {
        guard !isSuspended, !isClearing, let url = webView.url, PlaybackNavigation.permits(url) else { return false }
        let wasSignedIn = isSignedIn
        var operation = epoch
        var expectedScope = await credentials.snapshot().scope
        guard operation == epoch, !isSuspended, !isClearing else { return false }
        // Read only the account routing/configuration values needed by the native client.
        let script = """
        (() => {
          const c = window.ytcfg;
          if (!c || typeof c.get !== 'function') return null;
          return { loggedIn: c.get('LOGGED_IN') === true,
            account: c.get('DATASYNC_ID') || '', authUser: Number(c.get('SESSION_INDEX') || 0),
            delegated: c.get('DELEGATED_SESSION_ID') || '',
            key: c.get('INNERTUBE_API_KEY') || '',
            version: c.get('INNERTUBE_CLIENT_VERSION') || c.get('INNERTUBE_CONTEXT_CLIENT_VERSION') || '',
            visitor: c.get('VISITOR_DATA') || '' };
        })()
        """
        guard let values = try? await webView.evaluateJavaScript(script) as? [String: Any],
              operation == epoch, !isSuspended, !isClearing else { return false }
        guard values["loggedIn"] as? Bool == true else {
            isWorking = false
            // An expired session needs an explicit reauthentication; a page failure never erases cookies.
            if isSignedIn { errorMessage = AppLocalization.text("Open your account to check the YouTube Music session.") }
            return false
        }
        let index = values["authUser"] as? Int ?? 0
        guard (0...99).contains(index) else { return false }
        let delegated = values["delegated"] as? String ?? ""
        guard let accountIdentity = values["account"] as? String, !accountIdentity.isEmpty else {
            isWorking = false
            errorMessage = AppLocalization.text("YouTube Music has not confirmed the selected account. Reload the account page and try again.")
            return false
        }
        let identity = "\(accountIdentity):\(index):\(delegated)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let apiKey = values["key"] as? String, !apiKey.isEmpty,
           let version = values["version"] as? String, !version.isEmpty {
            currentConfiguration = MusicClientConfiguration(
                apiKey: apiKey, clientVersion: version, visitorData: values["visitor"] as? String)
        }
        let previousKey = accountKey ?? preferences.string(forKey: "lastAccount")
        let changed = previousKey != nil && previousKey != key
        if changed {
            epoch = UUID()
            operation = epoch
            isSignedIn = false
            onAccountChanged?(true)
            guard await credentials.clear(expectedScope: expectedScope) else { return false }
            guard operation == epoch, !isSuspended, !isClearing else { return false }
            expectedScope = await credentials.snapshot().scope
            guard operation == epoch, !isSuspended, !isClearing else { return false }
        }
        accountKey = key
        authUser = index
        delegatedSessionID = delegated.isEmpty ? nil : delegated
        await refreshCookies(replace: changed || !isSignedIn, expectedScope: expectedScope)
        guard operation == epoch, !isSuspended, !isClearing else { return false }
        if isSignedIn {
            isRestoringSession = false
            preferences.set(key, forKey: "lastAccount")
            preferences.set(false, forKey: "sessionRestoreBlocked")
            isWorking = false
            errorMessage = nil
            onAccountConfirmed?(key)
            if !wasSignedIn { onSignInCompleted?() }
        }
        return isSignedIn
    }

    private func refreshCookies(replace: Bool = false, expectedScope suppliedScope: UUID? = nil) async {
        guard !isSuspended, !isClearing, let accountKey,
              !preferences.bool(forKey: "sessionRestoreBlocked") || loginAttempt else { return }
        let operation = epoch
        let expectedScope: UUID
        if let suppliedScope { expectedScope = suppliedScope }
        else { expectedScope = await credentials.snapshot().scope }
        guard operation == epoch, !isSuspended, !isClearing else { return }
        let cookies = SessionPolicy.musicCookies(await dataStore.httpCookieStore.allCookies())
        guard operation == epoch, !isSuspended, !isClearing else { return }
        guard let secret = cookies.first(where: { $0.name == "SAPISID" })?.value
                ?? cookies.first(where: { $0.name == "__Secure-3PAPISID" })?.value,
              !secret.isEmpty else { return }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let accepted: Bool
        if replace || !isSignedIn {
            accepted = await credentials.replaceSession(accountID: accountKey, cookieHeader: header, sapisid: secret,
                configuration: currentConfiguration, delegatedSessionID: delegatedSessionID, authUser: authUser,
                expectedScope: expectedScope)
        } else {
            accepted = (try? await credentials.refreshCredentials(cookieHeader: header, sapisid: secret,
                configuration: currentConfiguration, expectedScope: expectedScope)) == true
        }
        guard accepted, operation == epoch, !isSuspended, !isClearing else { return }
        let wasSignedIn = isSignedIn
        isSignedIn = true
        if !wasSignedIn { onAccountChanged?(false) }
    }

    func signOut() async {
        preferences.set(true, forKey: "sessionRestoreBlocked")
        preferences.removeObject(forKey: "lastAccount")
        isClearing = true
        isRestoringSession = false
        epoch = UUID()
        refreshTask?.cancel()
        closeLogin()
        isSignedIn = false
        accountKey = nil
        currentConfiguration = nil
        delegatedSessionID = nil
        authUser = 0
        await credentials.clear()
        await clearWebsiteData()
        isClearing = false
        errorMessage = nil
    }

    private func clearWebsiteData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

extension WebSession: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, !self.isSuspended, !self.isClearing else { return }
            self.refreshTask?.cancel()
            self.refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await self?.refreshCookies()
            }
        }
    }
}

extension WebSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard acceptsLoginView(webView), let url = navigationAction.request.url, SessionPolicy.allowsLoginNavigation(url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard acceptsLoginView(webView) else { return }
        let operation = epoch
        Task { [weak self, weak webView] in
            guard let self, let webView, self.epoch == operation, self.acceptsLoginView(webView) else { return }
            await self.synchronize(from: webView)
            guard self.epoch == operation, self.acceptsLoginView(webView) else { return }
            self.isWorking = false
            if self.isSignedIn && !self.loginAttempt { self.closeLogin() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard acceptsLoginView(webView) else { return }
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isWorking = false
        errorMessage = AppLocalization.text("Could not open YouTube Music. Check your connection and try again.")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if acceptsLoginView(webView), let url = navigationAction.request.url, SessionPolicy.allowsLoginNavigation(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}
