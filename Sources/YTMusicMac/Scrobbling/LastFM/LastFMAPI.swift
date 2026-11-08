import CryptoKit
import Foundation
import MusicCore

struct LastFMAppCredentials: Codable, Equatable, Sendable {
    let apiKey: String
    let sharedSecret: String
    var isValid: Bool {
        apiKey.utf8.count == 32 && Self.printable(apiKey) && (1...256).contains(sharedSecret.utf8.count) && Self.printable(sharedSecret)
    }
    private static func printable(_ value: String) -> Bool { value.utf8.allSatisfy { (33...126).contains($0) } }
    var fingerprint: String { SHA256.hash(data: Data((apiKey + sharedSecret).utf8)).map { String(format: "%02x", $0) }.joined() }
    static func hex(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}
struct LastFMSavedCredentials: Codable, Equatable, Sendable {
    let application: LastFMAppCredentials
    var revision = UUID()
    var username: String?
    var sessionKey: String?
    var isValid: Bool {
        application.isValid && ((username == nil && sessionKey == nil) ||
            (username.map(LastFMDocument.validUsername) == true && sessionKey.map(LastFMAppCredentials.hex) == true))
    }
}
enum LastFMAPIError: Error, Equatable { case invalidCredentials, notAuthorized, expired, rejected, uncertain }
enum LastFMSubmissionOutcome: Sendable, Equatable { case confirmed, ignored, authenticationRejected, rejected, retryable, uncertain }

struct LastFMAPI: Sendable {
    let transport: any ScrobbleHTTPTransport

    /// Last.fm signs raw UTF-8 values before form encoding; response format and
    /// callback are explicitly excluded by its authentication specification.
    static func signature(_ parameters: [String: String], secret: String) -> String {
        let fields = parameters.keys.filter { !["format", "callback", "api_sig"].contains($0) }.sorted()
        let raw = fields.map { $0 + parameters[$0]! }.joined() + secret
        return Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func form(_ fields: [String: String]) -> String {
        func encoded(_ value: String) -> String {
            value.utf8.map { byte in
                switch byte {
                case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
                default: return String(format: "%%%02X", byte)
                }
            }.joined()
        }
        return fields.keys.sorted().map { encoded($0) + "=" + encoded(fields[$0]!) }.joined(separator: "&")
    }
    static func approvalURL(application: LastFMAppCredentials, token: String) -> URL? {
        guard application.isValid, LastFMAppCredentials.hex(token) else { return nil }
        var url = URLComponents(string: "https://www.last.fm/api/auth/")!
        url.queryItems = [URLQueryItem(name: "api_key", value: application.apiKey), URLQueryItem(name: "token", value: token)]
        return url.url
    }
    func requestToken(application: LastFMAppCredentials) async throws -> String {
        let request = try request(method: "auth.getToken", fields: [:], application: application)
        let object = try await authResponse(request)
        guard let token = object["token"] as? String, LastFMAppCredentials.hex(token) else { throw LastFMAPIError.uncertain }
        return token
    }
    func getSession(application: LastFMAppCredentials, token: String) async throws -> LastFMSavedCredentials {
        guard LastFMAppCredentials.hex(token) else { throw LastFMAPIError.invalidCredentials }
        let object = try await authResponse(request(method: "auth.getSession", fields: ["token": token], application: application))
        guard let session = object["session"] as? [String: Any], let name = session["name"] as? String,
              let key = session["key"] as? String, LastFMDocument.validUsername(name), LastFMAppCredentials.hex(key) else {
            throw LastFMAPIError.uncertain
        }
        return LastFMSavedCredentials(application: application, username: name, sessionKey: key)
    }
    func submit(_ listen: EarnedListen, credentials: LastFMSavedCredentials, chosenByUser: Bool? = nil,
                authorized: @Sendable () -> Bool = { true }) async -> LastFMSubmissionOutcome {
        do {
            try Task.checkCancellation()
            guard credentials.isValid, let key = credentials.sessionKey, credentials.username != nil,
                  listen.metadata.isValid, listen.duration.isFinite, (30.000_001...2_073_600).contains(listen.duration),
                  listen.listenedAt >= 1_033_430_400 else { return .rejected }
            var fields = ["artist": listen.metadata.artist, "track": listen.metadata.title,
                          "timestamp": String(listen.listenedAt), "duration": String(Int(listen.duration)), "sk": key]
            if let album = listen.metadata.album { fields["album"] = album }
            if let chosenByUser { fields["chosenByUser"] = chosenByUser ? "1" : "0" }
            // Queue provenance is optional; omit chosenByUser when it is unknown.
            let request = try request(method: "track.scrobble", fields: fields, application: credentials.application)
            guard authorized() else { return .uncertain }
            let response = try await transport.send(request)
            guard response.data.count <= 65_536,
                  let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { return .uncertain }
            if let error = Self.integer(object["error"]) {
                if error == 9 { return .authenticationRejected }
                if error == 11 || error == 16 { return .retryable }
                return .rejected
            }
            guard object["error"] == nil, response.statusCode == 200, let result = object["scrobbles"] as? [String: Any],
                  let attributes = result["@attr"] as? [String: Any],
                  let accepted = Self.integer(attributes["accepted"]), let ignored = Self.integer(attributes["ignored"]),
                  (0...1).contains(accepted), (0...1).contains(ignored), accepted + ignored == 1 else { return .uncertain }
            let row: [String: Any]?
            if let rows = result["scrobble"] as? [[String: Any]], rows.count == 1 { row = rows.first }
            else { row = result["scrobble"] as? [String: Any] }
            guard let row, let ignoredMessage = row["ignoredMessage"] as? [String: Any],
                  let code = Self.integer(ignoredMessage["code"]),
                  Self.integer(row["timestamp"]) == listen.listenedAt else { return .uncertain }
            if accepted == 1 && ignored == 0 && code == 0 { return .confirmed }
            if accepted == 0 && ignored == 1 && (1...5).contains(code) { return .ignored }
            return .uncertain
        } catch { return .uncertain }
    }
    private func authResponse(_ request: URLRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        let response: ScrobbleHTTPResponse
        do { response = try await transport.send(request) } catch { throw LastFMAPIError.uncertain }
        guard response.data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw LastFMAPIError.uncertain }
        if let error = Self.integer(object["error"]) {
            if error == 14 { throw LastFMAPIError.notAuthorized }
            if error == 15 { throw LastFMAPIError.expired }
            throw LastFMAPIError.rejected
        }
        guard object["error"] == nil, response.statusCode == 200 else { throw LastFMAPIError.uncertain }
        return object
    }
    private func request(method: String, fields: [String: String], application: LastFMAppCredentials) throws -> URLRequest {
        guard application.isValid else { throw LastFMAPIError.invalidCredentials }
        var fields = fields
        fields["method"] = method; fields["api_key"] = application.apiKey
        fields["api_sig"] = Self.signature(fields, secret: application.sharedSecret)
        fields["format"] = "json"
        let encoded = Self.form(fields)
        guard encoded.utf8.count <= 16_384 else { throw LastFMAPIError.invalidCredentials }
        var url = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        if method != "track.scrobble" { url.percentEncodedQuery = encoded }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method == "track.scrobble" ? "POST" : "GET"
        if request.httpMethod == "POST" { request.httpBody = Data(encoded.utf8) }
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("YTMusicMac (https://github.com/z11r/yt-music-mac)", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func integer(_ value: Any?) -> Int? {
        if let string = value as? String, !string.isEmpty, string.utf8.allSatisfy({ (48...57).contains($0) }) { return Int(string) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue == Double(value.intValue) { return value.intValue }
        return nil
    }
}
