import Foundation
import Testing
import Flux
import FluxTestStore

@MainActor
struct TestStoreFinishTests {
    @Test func finishIsImmediateWithoutEffectsAndCanBeRepeated() async {
        let store = TestStore<FinishFeature>(state: .init())
        store.dispatch(.start) { _ in }
        await store.finish()
        await store.finish()
        store.dispatch(.done) { $0.count = 1 }
        await store.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func finishSuspendsRatherThanBlockingMainActor() async {
        let gate = FinishGate()
        let store = TestStore<FinishFeature>(state: .init(), middlewares: [TestMiddleware<FinishFeature> { _, _ in
            await gate.wait()
            return nil
        }])
        store.dispatch(.start) { _ in }
        await gate.started.wait()
        let observer = FinishObserver()
        let task = Task {
            observer.started.open()
            await store.finish()
            observer.didFinish = true
        }
        await observer.started.wait()
        #expect(!observer.didFinish)

        gate.open()
        await task.value
        #expect(observer.didFinish)
        store.tearDown() // Nonblocking final assertions after the async drain.
    }

    @Test(.timeLimit(.minutes(1)))
    func finishIncludesFollowUpMiddlewareTasks() async {
        let initial = FinishGate()
        let final = FinishGate()
        let store = TestStore<FinishFeature>(state: .init(), middlewares: [TestMiddleware<FinishFeature> { _, action in
            switch action {
            case .start:
                await initial.wait()
                return .step
            case .step: return .done
            case .done:
                await final.wait()
                return nil
            }
        }])
        store.dispatch(.start) { _ in }
        await initial.started.wait()
        let observer = FinishObserver()
        let task = Task {
            await withKnownIssue("finish must still wait for a descendant born after it started", isolation: MainActor.shared) {
                observer.started.open()
                await store.finish(timeout: 1)
            } when: { true } matching: { issue in
                issue.comments.contains { $0.rawValue.contains("Timed out or cancelled while finishing") }
            }
        }
        await observer.started.wait()
        initial.open()
        await store.receive([.step, .done]) { $0.count = 2 }
        await final.started.wait()

        // The last descendant stays blocked: finish must time out, not return when
        // just its original task completes. Unexpected unreceived-action issues do not match.
        await task.value
        final.open()
        await store.finish()
        #expect(store.state.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func finishWaitsForAllMiddlewareTasks() async {
        let first = FinishGate()
        let second = FinishGate()
        let firstCompleted = FinishSignal()
        let store = TestStore<FinishFeature>(state: .init(), middlewares: [
            TestMiddleware<FinishFeature> { _, _ in
                await first.wait()
                firstCompleted.open()
                return nil
            },
            TestMiddleware<FinishFeature> { _, _ in
                await second.wait()
                return nil
            }
        ])
        store.dispatch(.start) { _ in }
        await first.started.wait()
        await second.started.wait()
        let observer = FinishObserver()
        let task = Task {
            await withKnownIssue("finish must still wait for the second middleware", isolation: MainActor.shared) {
                observer.started.open()
                await store.finish(timeout: 1)
            } when: { true } matching: { issue in
                issue.comments.contains { $0.rawValue.contains("Timed out or cancelled while finishing") }
            }
        }
        await observer.started.wait()

        first.open()
        await firstCompleted.wait()
        // Keep the second task blocked. Returning after only the first task would
        // fail the expected timeout diagnostic, regardless of task scheduling order.
        await task.value
        second.open()
        await store.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func tearDownOnlyChecksAndDoesNotWaitForRunningWork() async {
        let gate = FinishGate()
        let store = TestStore<FinishFeature>(state: .init(), middlewares: [TestMiddleware<FinishFeature> { _, _ in
            await gate.wait()
            return nil
        }])
        store.dispatch(.start) { _ in }
        await gate.started.wait()
        withKnownIssue("tearDown must diagnose pending work without draining it") {
            store.tearDown()
        }
        gate.open()
        await store.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingFinishCancelsMiddlewareWork() async {
        let started = FinishSignal()
        let cancelled = FinishSignal()
        let store = TestStore<FinishFeature>(state: .init(), middlewares: [TestMiddleware<FinishFeature> { _, _ in
            started.open()
            do {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            } catch {
                cancelled.open()
            }
            return nil
        }])
        store.dispatch(.start) { _ in }
        await started.wait()
        await withKnownIssue("finish must report cancellation of pending work") {
            let task = Task { await store.finish() }
            task.cancel()
            await task.value
        }
        await cancelled.wait()
        await store.finish()
    }

    @Test func finishReportsUnreceivedActions() async {
        let store = TestStore<FinishFeature>(state: .init())
        store.dispatch(.done)
        await withKnownIssue("finish must diagnose unreceived actions") {
            await store.finish()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutReportsAndCancelsRemainingWorkWithoutDispatchingItsResponse() async {
        let started = FinishSignal()
        let cancelled = FinishSignal()
        let store = TestStore<FinishFeature>(state: .init(), middlewares: [TestMiddleware<FinishFeature> { _, _ in
            started.open()
            do {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            } catch {
                cancelled.open()
            }
            return .done // A cancelled effect must not dispatch this response.
        }])
        store.dispatch(.start) { _ in }
        await started.wait()
        await withKnownIssue("finish must diagnose its timeout") {
            await store.finish(timeout: 0)
        }
        await cancelled.wait()
        await store.finish()
        #expect(store.state.count == 0)
    }
}

private struct FinishFeature: Feature {
    struct State: Equatable, Sendable { var count = 0 }
    enum Action: Equatable, Sendable { case start, step, done }

    func reduce(_ state: inout State, _ action: Action) {
        switch action {
        case .start: break
        case .step, .done: state.count += 1
        }
    }
}

@MainActor
private final class FinishSignal {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func open() { continuation.finish() }
    func wait() async { for await _ in stream {} }
}

@MainActor
private final class FinishGate {
    let started = FinishSignal()
    private let released = FinishSignal()
    func wait() async {
        started.open()
        await released.wait()
    }
    func open() { released.open() }
}

@MainActor
private final class FinishObserver {
    let started = FinishSignal()
    var didFinish = false
}
