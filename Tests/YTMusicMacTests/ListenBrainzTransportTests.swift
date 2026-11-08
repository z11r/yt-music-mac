import Foundation
import XCTest
@testable import YTMusicMac

@MainActor
final class ListenBrainzTransportTests: XCTestCase {
    func testNormalResponsePreservesStatusHeadersAndBody() async throws {
        let plan = ProtocolPlan(.body([Data("one".utf8), Data("two".utf8)], declaredLength: 6))
        let response = try await transport(limit: 8).send(request(plan))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["x-fixture"], "present")
        XCTAssertEqual(response.data, Data("onetwo".utf8))
        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertFalse(try XCTUnwrap(plan.requests.first).httpShouldHandleCookies)
    }

    func testBodyExactlyAtLimitIsAccepted() async throws {
        let plan = ProtocolPlan(.body([Data(repeating: 1, count: 8)], declaredLength: nil))
        let response = try await transport(limit: 8).send(request(plan))
        XCTAssertEqual(response.data.count, 8)
    }

    func testOversizedDeclaredLengthIsRejectedBeforeBodyIsNeeded() async {
        let plan = ProtocolPlan(.body([], declaredLength: 9))
        do { _ = try await transport(limit: 8).send(request(plan)); XCTFail("Expected a response size error") }
        catch { XCTAssertEqual(error as? ScrobbleNetworkError, .invalidResponse) }
    }

    func testStreamedBodyWithoutContentLengthIsCapped() async {
        let plan = ProtocolPlan(.body([Data(repeating: 1, count: 5), Data(repeating: 2, count: 5)], declaredLength: nil))
        do { _ = try await transport(limit: 8).send(request(plan)); XCTFail("Expected a response size error") }
        catch { XCTAssertEqual(error as? ScrobbleNetworkError, .invalidResponse) }
    }

    func testBodyCannotExceedItsDeclaredLengthAndTransferLimit() async {
        let plan = ProtocolPlan(.body([Data(repeating: 1, count: 5), Data(repeating: 2, count: 5)], declaredLength: 4))
        do { _ = try await transport(limit: 8).send(request(plan)); XCTFail("Expected a response size error") }
        catch { XCTAssertEqual(error as? ScrobbleNetworkError, .invalidResponse) }
    }

    func testCancellationStopsAnInFlightTransfer() async {
        let plan = ProtocolPlan(.pending)
        let transport = transport()
        let request = request(plan)
        let task = Task { try await transport.send(request) }
        await plan.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await plan.waitUntilStopped()
        XCTAssertTrue(plan.didStop)
    }

    func testCancellationBeforeStartingDoesNotCreateARequest() async {
        let plan = ProtocolPlan(.pending)
        let transport = transport()
        let request = request(plan)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(plan.requests.isEmpty)
    }

    func testRedirectNeverForwardsExplicitCredentials() async throws {
        let plan = ProtocolPlan(.redirect)
        var request = request(plan)
        request.setValue("fixture-session=value", forHTTPHeaderField: "Cookie")
        request.setValue("fixture-authorization", forHTTPHeaderField: "Authorization")
        let response = try await transport().send(request)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertEqual(plan.requests.first?.url?.host, "api.listenbrainz.org")
        XCTAssertNil(plan.requests.first?.value(forHTTPHeaderField: "Cookie"))
    }

    func testNetworkErrorKeepsItsOriginalClassification() async {
        let plan = ProtocolPlan(.failure(.notConnectedToInternet))
        do { _ = try await transport().send(request(plan)); XCTFail("Expected network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testOnlyTheSecureProviderOriginCanBeRequested() async {
        for raw in ["http://api.listenbrainz.org/", "https://example.invalid/", "https://api.listenbrainz.org.example.invalid/",
                    "https://fixture@api.listenbrainz.org/", "https://api.listenbrainz.org:8443/"] {
            let plan = ProtocolPlan(.body([], declaredLength: 0))
            do { _ = try await transport().send(request(plan, url: URL(string: raw)!)); XCTFail("Expected origin rejection") }
            catch { XCTAssertEqual(error as? ScrobbleNetworkError, .invalidRequest) }
            XCTAssertTrue(plan.requests.isEmpty)
        }
    }

    func testConcurrentTransfersKeepTheirBodiesSeparate() async throws {
        let transport = transport(limit: 16)
        let first = request(ProtocolPlan(.body([Data("first".utf8)], declaredLength: nil)))
        let second = request(ProtocolPlan(.body([Data("second".utf8)], declaredLength: nil)))
        async let firstResponse = transport.send(first)
        async let secondResponse = transport.send(second)
        let results = try await (firstResponse, secondResponse)
        XCTAssertEqual(results.0.data, Data("first".utf8))
        XCTAssertEqual(results.1.data, Data("second".utf8))
    }

    func testConfigurationCopyDoesNotMutateTheCallersConfiguration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        let transport = ListenBrainzHTTPTransport(configuration: configuration, maximumResponseBytes: 8)
        _ = try await transport.send(request(ProtocolPlan(.body([], declaredLength: 0))))
        XCTAssertTrue(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .returnCacheDataElseLoad)
    }

    func testOnlyProviderHeadersSurviveTheCopiedRequestAndConfiguration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "configuration-fixture", "X-Goog-AuthUser": "7"]
        let client = ListenBrainzHTTPTransport(configuration: configuration)
        let plan = ProtocolPlan(.body([], declaredLength: 0))
        var value = request(plan)
        for key in ["Cookie", "X-Goog-AuthUser", "Referer", "X-Fixture-Secret"] { value.setValue("request-fixture", forHTTPHeaderField: key) }
        value.setValue("Token provider-fixture", forHTTPHeaderField: "Authorization")
        _ = try await client.send(value)
        let sent = try XCTUnwrap(plan.requests.first)
        for key in ["Cookie", "X-Goog-AuthUser", "Referer", "X-Fixture-Secret"] { XCTAssertNil(sent.value(forHTTPHeaderField: key)) }
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Token provider-fixture")
    }

    func testUnknownPathsQueriesAndOversizedBodiesNeverStartARequest() async {
        for raw in ["https://api.listenbrainz.org/1/unknown", "https://api.listenbrainz.org/1/validate-token?token=fixture"] {
            let plan = ProtocolPlan(.body([], declaredLength: 0))
            do { _ = try await transport().send(request(plan, url: URL(string: raw)!)); XCTFail("Expected path rejection") }
            catch { XCTAssertEqual(error as? ScrobbleNetworkError, .invalidRequest) }
            XCTAssertTrue(plan.requests.isEmpty)
        }
        let plan = ProtocolPlan(.body([], declaredLength: 0))
        var value = request(plan, url: URL(string: "https://api.listenbrainz.org/1/submit-listens")!)
        value.httpMethod = "POST"; value.httpBody = Data(repeating: 1, count: 16_385)
        do { _ = try await transport().send(value); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(error as? ScrobbleNetworkError, .invalidRequest) }
        XCTAssertTrue(plan.requests.isEmpty)
    }

    private func transport(limit: Int = 128) -> ListenBrainzHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return ListenBrainzHTTPTransport(configuration: configuration, maximumResponseBytes: limit)
    }

    private func request(_ plan: ProtocolPlan, url: URL = URL(string: "https://api.listenbrainz.org/1/validate-token")!) -> URLRequest {
        let request = NSMutableURLRequest(url: url)
        request.httpMethod = "GET"
        URLProtocol.setProperty(plan, forKey: FixtureURLProtocol.planKey, in: request)
        return request as URLRequest
    }
}

/// Each request owns its fixture plan. No global cookie store, request handler, or response cache is changed.
private final class ProtocolPlan: NSObject, @unchecked Sendable {
    enum Mode: Sendable {
        case body([Data], declaredLength: Int?)
        case pending
        case redirect
        case failure(URLError.Code)
    }
    let mode: Mode
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []
    private var stopped = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var requests: [URLRequest] { lock.withLock { capturedRequests } }
    var didStop: Bool { lock.withLock { stopped } }

    init(_ mode: Mode) { self.mode = mode }

    func started(_ request: URLRequest) {
        let captured = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.removeProperty(forKey: FixtureURLProtocol.planKey, in: captured)
        let waiters = lock.withLock {
            capturedRequests.append(captured as URLRequest)
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func didStopLoading() {
        let waiters = lock.withLock {
            stopped = true
            let waiters = stopWaiters
            stopWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if !capturedRequests.isEmpty { return true }
                startWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if stopped { return true }
                stopWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let planKey = "ListenBrainzTransportFixturePlan"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var plan: ProtocolPlan? { URLProtocol.property(forKey: Self.planKey, in: request) as? ProtocolPlan }

    override func startLoading() {
        guard let plan, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        plan.started(request)
        switch plan.mode {
        case let .body(chunks, declaredLength):
            var headers = ["X-Fixture": "present"]
            if let declaredLength { headers["Content-Length"] = String(declaredLength) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .pending:
            break
        case .redirect:
            if url.host != "api.listenbrainz.org" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let destination = URL(string: "https://example.invalid/destination")!
            var redirected = request
            redirected.url = destination
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() { plan?.didStopLoading() }
}
