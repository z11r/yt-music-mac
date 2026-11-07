import Foundation

/// Values supplied by the loaded web client, held only in memory.
public struct MusicClientConfiguration: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let apiKey: String
    public let clientVersion: String
    public let visitorData: String?
    public let language: String
    public let region: String

    public init(apiKey: String, clientVersion: String, visitorData: String? = nil, language: String = "en", region: String = "US") {
        self.apiKey = apiKey
        self.clientVersion = clientVersion
        self.visitorData = visitorData
        self.language = language
        self.region = region
    }

    public var description: String { "MusicClientConfiguration" }
    public var debugDescription: String { description }
}

public struct MusicSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let scope: UUID
    public let accountID: String?
    public let cookieHeader: String?
    public let sapisid: String?
    public let configuration: MusicClientConfiguration?
    public let delegatedSessionID: String?
    public let authUser: Int
    public var isAuthenticated: Bool { accountID != nil && cookieHeader?.isEmpty == false && sapisid?.isEmpty == false }
    public var description: String { "MusicSession(authenticated: \(isAuthenticated))" }
    public var debugDescription: String { description }

    public init(scope: UUID, accountID: String? = nil, cookieHeader: String? = nil, sapisid: String? = nil,
                configuration: MusicClientConfiguration? = nil, delegatedSessionID: String? = nil, authUser: Int = 0) {
        self.scope = scope
        self.accountID = accountID
        self.cookieHeader = cookieHeader
        self.sapisid = sapisid
        self.configuration = configuration
        self.delegatedSessionID = delegatedSessionID
        self.authUser = authUser
    }
}

public protocol MusicSessionProviding: Sendable {
    func snapshot() async -> MusicSession
}

/// The app supplies credentials from its own web session. No browser profiles or keychain items are read here.
public actor MusicSessionStore: MusicSessionProviding {
    private var current = MusicSession(scope: UUID())

    public init() {}
    public func snapshot() -> MusicSession { current }

    /// Changing any session material fences pending responses and existing continuation tokens.
    @discardableResult
    public func replaceSession(accountID: String, cookieHeader: String, sapisid: String,
                               configuration: MusicClientConfiguration? = nil,
                               delegatedSessionID: String? = nil, authUser: Int = 0,
                               expectedScope: UUID? = nil) -> Bool {
        guard acceptsMutation(expectedScope: expectedScope) else { return false }
        guard current.accountID != accountID || current.cookieHeader != cookieHeader || current.sapisid != sapisid
                || current.configuration != configuration || current.delegatedSessionID != delegatedSessionID
                || current.authUser != authUser else { return true }
        current = MusicSession(scope: UUID(), accountID: accountID, cookieHeader: cookieHeader, sapisid: sapisid,
                               configuration: configuration, delegatedSessionID: delegatedSessionID, authUser: authUser)
        return true
    }

    /// Refreshes visitor/preference cookies without discarding pages for the same identity.
    /// A changed authentication secret still creates a fence. Use replaceSession for account changes.
    @discardableResult
    public func refreshCredentials(cookieHeader: String, sapisid: String,
                                   configuration: MusicClientConfiguration? = nil,
                                   expectedScope: UUID? = nil) throws -> Bool {
        guard acceptsMutation(expectedScope: expectedScope) else { return false }
        guard let accountID = current.accountID else { throw MusicServiceError.signInRequired }
        let scope = current.sapisid == sapisid ? current.scope : UUID()
        current = MusicSession(scope: scope, accountID: accountID, cookieHeader: cookieHeader, sapisid: sapisid,
                               configuration: configuration ?? current.configuration,
                               delegatedSessionID: current.delegatedSessionID, authUser: current.authUser)
        return true
    }

    private func acceptsMutation(expectedScope: UUID?) -> Bool {
        !Task.isCancelled && (expectedScope == nil || expectedScope == current.scope)
    }

    /// A conditional clear fences account changes; an unconditional clear always completes sign-out.
    @discardableResult
    public func clear(expectedScope: UUID? = nil) -> Bool {
        if expectedScope != nil && !acceptsMutation(expectedScope: expectedScope) { return false }
        current = MusicSession(scope: UUID())
        return true
    }
}
