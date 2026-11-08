import Foundation
import XCTest
@testable import YouTubeMusic

@MainActor final class MusicTransferSettlementTests: XCTestCase {
    func testCanceledReadRetainsItsSlotUntilTheExactNativeCompletion() async throws {
        let transfer = MusicTransfer(maximumResponseBytes: 8), native = SettlementTask(id: 10)
        let finished = SettlementFlag()
        let read = Task {
            defer { finished.set() }
            return try await transfer.response { native.created(); return native }
        }
        await native.waitForResume(); read.cancel(); await native.waitForCancel()
        XCTAssertTrue(transfer.hasPendingTask)
        XCTAssertFalse(finished.value)
        XCTAssertFalse(transfer.receive(response()))
        transfer.append(Data(repeating: 1, count: 64))
        transfer.complete(taskIdentifier: 11, error: nil)
        XCTAssertTrue(transfer.hasPendingTask)
        XCTAssertFalse(finished.value)
        transfer.complete(taskIdentifier: 10, error: URLError(.cancelled))
        do { _ = try await read.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(transfer.hasPendingTask)
        transfer.complete(taskIdentifier: 10, error: nil)
        XCTAssertEqual(native.counts, [1, 1, 1])
    }
    func testPreCreationFailureAndPreCanceledTaskCreateNoNativeTask() async {
        for canceledTask in [false, true] {
            let transfer = MusicTransfer(maximumResponseBytes: 8), native = SettlementTask(id: 20)
            if !canceledTask { transfer.fail(CancellationError()) }
            let read = Task {
                if canceledTask { withUnsafeCurrentTask { $0?.cancel() } }
                return try await transfer.response { native.created(); return native }
            }
            do { _ = try await read.value; XCTFail("Expected pre-creation cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(native.counts, [0, 0, 0]); XCTAssertFalse(transfer.hasPendingTask)
        }
    }
    func testCancellationRacingCreationCancelsOnlyAfterTheSuspendedTaskIsRegistered() async {
        let transfer = MusicTransfer(maximumResponseBytes: 8), native = SettlementTask(id: 30)
        let entered = SettlementLatch(), release = SettlementLatch(), finished = SettlementFlag()
        let read = Task.detached {
            defer { finished.set() }
            return try await transfer.response {
                native.created(); entered.open(); release.wait()
                return native
            }
        }
        await entered.waitAsync()
        // Cancellation runs concurrently while the deliberately held fake factory
        // owns creation admission; the production factory never blocks here.
        let canceled = Task.detached { read.cancel() }
        release.open(); await canceled.value
        await native.waitForCancel(); await native.waitForResume()
        XCTAssertTrue(transfer.hasPendingTask); XCTAssertFalse(finished.value)
        XCTAssertEqual(native.counts, [1, 1, 1])
        transfer.complete(taskIdentifier: 30, error: URLError(.cancelled))
        do { _ = try await read.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testDeclaredAndChunkLimitFailuresWaitForCompletionAndKeepTheirSemanticPriority() async {
        for declared in [true, false] {
            let transfer = MusicTransfer(maximumResponseBytes: 8), native = SettlementTask(id: 40)
            let finished = SettlementFlag()
            let read = Task {
                defer { finished.set() }
                return try await transfer.response { native.created(); return native }
            }
            await native.waitForResume()
            if declared { XCTAssertFalse(transfer.receive(response(length: 9))) }
            else {
                XCTAssertTrue(transfer.receive(response()))
                transfer.append(Data(repeating: 1, count: 5)); transfer.append(Data(repeating: 2, count: 5))
            }
            await native.waitForCancel()
            transfer.fail(CancellationError()); transfer.append(Data("late".utf8))
            XCTAssertFalse(finished.value); XCTAssertTrue(transfer.hasPendingTask)
            transfer.complete(taskIdentifier: 40, error: URLError(.cancelled))
            do { _ = try await read.value; XCTFail("Expected original limit error") }
            catch { XCTAssertEqual(error as? MusicServiceError, .invalidResponse) }
            XCTAssertFalse(transfer.hasPendingTask); XCTAssertEqual(native.counts, [1, 1, 1])
        }
    }
    func testATransferCannotReplaceAnAdmittedContinuationOrReplayACompletedResponse() async throws {
        let transfer = MusicTransfer(maximumResponseBytes: 8), native = SettlementTask(id: 45)
        let read = Task { try await transfer.response { native.created(); return native } }
        await native.waitForResume()
        for completed in [false, true] {
            if completed {
                XCTAssertTrue(transfer.receive(response()))
                transfer.complete(taskIdentifier: 45, error: nil)
                _ = try await read.value
            }
            do { _ = try await transfer.response { native.created(); return native }; XCTFail("Expected one-shot admission") }
            catch { XCTAssertEqual(error as? MusicServiceError, .invalidResponse) }
        }
        XCTAssertEqual(native.counts, [1, 1, 0])
    }
    func testNativeNetworkErrorAndMissingResponseSettleOnlyAtCompletion() async {
        for hasError in [true, false] {
            let transfer = MusicTransfer(maximumResponseBytes: 8), native = SettlementTask(id: 50)
            let read = Task { try await transfer.response { native.created(); return native } }
            await native.waitForResume()
            XCTAssertTrue(transfer.hasPendingTask)
            transfer.complete(taskIdentifier: 50, error: hasError ? URLError(.notConnectedToInternet) : nil)
            do { _ = try await read.value; XCTFail("Expected error") }
            catch {
                if hasError { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
                else { XCTAssertEqual(error as? MusicServiceError, .invalidResponse) }
            }
        }
    }
    func testSuccessPreservesBodyStatusHeadersAndIgnoresLateOrDuplicateCallbacks() async throws {
        let transfer = MusicTransfer(maximumResponseBytes: 8), native = SettlementTask(id: 60)
        let read = Task { try await transfer.response { native.created(); return native } }
        await native.waitForResume()
        XCTAssertTrue(transfer.receive(response(status: 302)))
        transfer.append(Data("fixture".utf8))
        transfer.complete(taskIdentifier: 60, error: nil)
        transfer.fail(CancellationError()); transfer.append(Data("late".utf8)); transfer.complete(taskIdentifier: 60, error: URLError(.cancelled))
        let result = try await read.value
        XCTAssertEqual(result.statusCode, 302); XCTAssertEqual(result.data, Data("fixture".utf8))
        XCTAssertEqual(result.headers["x-fixture"], "kept"); XCTAssertEqual(native.counts, [1, 1, 0])
    }
    private func response(length: Int? = nil, status: Int = 200) -> HTTPURLResponse {
        var headers = ["X-Fixture": "kept"]
        if let length { headers["Content-Length"] = String(length) }
        return HTTPURLResponse(url: URL(string: "https://music.youtube.com/synthetic")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
private final class SettlementFlag: @unchecked Sendable {
    private let lock = NSLock(); private var setValue = false
    var value: Bool { lock.withLock { setValue } }
    func set() { lock.withLock { setValue = true } }
}
private final class SettlementTask: MusicTransportTask, @unchecked Sendable {
    let taskIdentifier: Int
    private let lock = NSLock()
    private var createdCount = 0, resumed = 0, canceled = 0
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = [], cancelWaiters: [CheckedContinuation<Void, Never>] = []
    init(id: Int) { taskIdentifier = id }
    var counts: [Int] { lock.withLock { [createdCount, resumed, canceled] } }
    func created() { lock.withLock { createdCount += 1 } }
    func resume() {
        let waiting = lock.withLock { resumed += 1; defer { resumeWaiters = [] }; return resumeWaiters }
        waiting.forEach { $0.resume() }
    }
    func cancel() {
        let waiting = lock.withLock { canceled += 1; defer { cancelWaiters = [] }; return cancelWaiters }
        waiting.forEach { $0.resume() }
    }
    func waitForResume() async { await withCheckedContinuation { c in let ready = lock.withLock { if resumed > 0 { return true }; resumeWaiters.append(c); return false }; if ready { c.resume() } } }
    func waitForCancel() async { await withCheckedContinuation { c in let ready = lock.withLock { if canceled > 0 { return true }; cancelWaiters.append(c); return false }; if ready { c.resume() } } }
}
private final class SettlementLatch: @unchecked Sendable {
    private let condition = NSCondition(); private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        condition.lock(); opened = true; let pending = waiters; waiters = []; condition.broadcast(); condition.unlock()
        pending.forEach { $0.resume() }
    }
    func wait() { condition.lock(); while !opened { condition.wait() }; condition.unlock() }
    func waitAsync() async { await withCheckedContinuation { c in condition.lock(); if opened { condition.unlock(); c.resume() } else { waiters.append(c); condition.unlock() } } }
}
