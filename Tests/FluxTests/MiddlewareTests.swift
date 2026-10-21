import Flux
import FluxTestStore
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MiddlewareTests {
    @Test func initializesMiddlewareOnceWithReadableState() {
        let middleware = ContextMiddleware()
        let store = FluxStore<TestFeature>(state: .init(count: 42), middlewares: [middleware])

        #expect(middleware.initializations == 1)
        #expect(middleware.initialCount == 42)
        #expect(middleware.store?.getState() == store.state)
    }

    @Test func contextDispatchReducesBeforeReadingState() {
        let middleware = ContextMiddleware()
        let store = FluxStore<TestFeature>(state: .init(), middlewares: [middleware])

        middleware.store?.dispatch(.increment)

        #expect(store.state.count == 1)
        #expect(middleware.store?.getState()?.count == 1)
    }

    @Test func contextDoesNotRetainStoreAndBecomesInertAfterRelease() {
        let middleware = ContextMiddleware()
        var store: FluxStore<TestFeature>? = FluxStore(state: .init(), middlewares: [middleware])
        weak var reference = store
        let handle = middleware.store

        store = nil

        #expect(reference == nil)
        #expect(handle?.getState() == nil)
        handle?.dispatch(.increment)
    }

    @Test func eachActionReceivesItsOwnPostReducerSnapshot() async {
        let observations = AsyncStream<Int>.makeStream()
        defer { observations.continuation.finish() }
        let store = FluxStore<TestFeature>(state: .init(), middlewares: [
            TestMiddleware<TestFeature> { state, _ in
                observations.continuation.yield(state.count)
                return nil
            }
        ])

        store.dispatch(.increment)
        store.dispatch(.increment)

        var iterator = observations.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(Set([first, second]) == Set([1, 2]))
    }

    @Test func suspendedMiddlewareDoesNotRetainStoreOrDispatchAfterRelease() async {
        let gate = MiddlewareGate()
        let middleware = ContextMiddleware()
        middleware.operation = { _, action in
            guard action == .load else { return nil }
            await gate.wait()
            return .increment
        }
        var store: FluxStore<TestFeature>? = FluxStore(state: .init(), middlewares: [middleware])
        weak var reference = store
        store?.dispatch(.load)
        await gate.started.wait()

        store = nil
        #expect(reference == nil)
        gate.released.open()
        await middleware.completed.wait()
        #expect(middleware.store?.getState() == nil)
    }

    @Test func slowMiddlewareDoesNotDelayOtherMiddleware() async {
        let gate = MiddlewareGate()
        let otherStarted = MiddlewareSignal()
        let slowFinished = MiddlewareSignal()
        let store = FluxStore<TestFeature>(state: .init(), middlewares: [
            TestMiddleware<TestFeature> { _, _ in
                await gate.wait()
                slowFinished.open()
                return nil
            },
            TestMiddleware<TestFeature> { _, _ in
                otherStarted.open()
                return nil
            }
        ])

        store.dispatch(.load)
        await gate.started.wait()
        await otherStarted.wait()
        gate.released.open()
        await slowFinished.wait()
    }

    @Test func testStoreInitializesAndRecordsContextDispatchedActions() async {
        let middleware = ContextMiddleware()
        middleware.operation = { [weak middleware] _, action in
            guard action == .load else { return nil }
            middleware?.store?.dispatch(.increment)
            #expect(middleware?.store?.getState()?.count == 1)
            return .decrement
        }
        let store = TestStore<TestFeature>(state: .init(), middlewares: [middleware])
        defer { store.tearDown() }
        #expect(middleware.initializations == 1)
        #expect(middleware.initialCount == 0)

        store.dispatch(.load) { _ in }
        await store.receive([.increment, .decrement]) { _ in }
        await store.finish()
        #expect(store.state.count == 0)
    }

    @Test func testStoreContextDoesNotRetainStore() {
        let middleware = ContextMiddleware()
        var store: TestStore<TestFeature>? = TestStore(state: .init(), middlewares: [middleware])
        weak var reference = store

        store = nil

        #expect(reference == nil)
        #expect(middleware.store?.getState() == nil)
        middleware.store?.dispatch(.increment)
    }

    @Test func testStoreRecordsStreamUpdatesDispatchedThroughHandle() async {
        let updates = AsyncStream<Void>.makeStream()
        let middleware = StreamMiddleware(updates: updates.stream)
        let store = TestStore<TestFeature>(state: .init(), middlewares: [middleware])
        defer {
            updates.continuation.finish()
            store.tearDown()
        }

        store.dispatch(.load) { _ in }
        await store.finish()
        // Subscription tasks belong to middleware, not finish(). Stop them explicitly.
        let emission = Task { updates.continuation.yield(()) }
        await store.receive(.increment) { $0.count = 1 }
        _ = await emission.value
        await middleware.stop()
        await store.finish()
    }

    @Test func suspendedMiddlewareDoesNotRetainTestStore() async {
        let gate = MiddlewareGate()
        let middleware = ContextMiddleware()
        middleware.operation = { _, _ in
            await gate.wait()
            return .increment
        }
        var store: TestStore<TestFeature>? = TestStore(state: .init(), middlewares: [middleware])
        weak var reference = store
        store?.dispatch(.load) { _ in }
        await gate.started.wait()

        store = nil
        #expect(reference == nil)
        gate.released.open()
        await middleware.completed.wait()
        #expect(middleware.store?.getState() == nil)
    }

    @Test func testStoreCapturesStateBeforeSchedulingMiddleware() async {
        let observations = AsyncStream<Int>.makeStream()
        defer { observations.continuation.finish() }
        let store = TestStore<TestFeature>(state: .init(), middlewares: [
            TestMiddleware<TestFeature> { state, _ in
                observations.continuation.yield(state.count)
                return nil
            }
        ])
        defer { store.tearDown() }

        store.dispatch(.increment) { $0.count = 1 }
        store.dispatch(.increment) { $0.count = 2 }
        await store.finish()

        var iterator = observations.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(Set([first, second]) == Set([1, 2]))
    }
}

@MainActor
private final class ContextMiddleware: Middleware {
    typealias F = TestFeature
    var store: StoreHandle<F>?
    var initializations = 0
    var initialCount: Int?
    let completed = MiddlewareSignal()
    var operation: (@MainActor (F.State, F.Action) async -> F.Action?)?

    func initialize(_ store: StoreHandle<F>) {
        initializations += 1
        initialCount = store.getState()?.count
        self.store = store
    }

    func after(_ state: F.State, _ action: F.Action) async -> F.Action? {
        defer { completed.open() }
        return await operation?(state, action)
    }
}

@MainActor
private final class StreamMiddleware: Middleware {
    typealias F = TestFeature
    private let updates: AsyncStream<Void>
    private var observation: Task<Void, Never>?

    init(updates: AsyncStream<Void>) { self.updates = updates }

    func initialize(_ store: StoreHandle<F>) {
        let updates = updates
        observation = Task {
            for await _ in updates {
                guard !Task.isCancelled else { return }
                store.dispatch(.increment)
            }
        }
    }

    func after(_ state: F.State, _ action: F.Action) async -> F.Action? { nil }

    func stop() async {
        observation?.cancel()
        await observation?.value
        observation = nil
    }

    deinit { observation?.cancel() }
}

@MainActor
private final class MiddlewareSignal {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func open() { continuation.finish() }
    func wait() async { for await _ in stream {} }
}

@MainActor
private final class MiddlewareGate {
    let started = MiddlewareSignal()
    let released = MiddlewareSignal()

    func wait() async {
        started.open()
        await released.wait()
    }
}
