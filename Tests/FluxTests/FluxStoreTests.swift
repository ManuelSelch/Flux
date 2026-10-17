import Combine
import Flux
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FluxStoreTests {
    @Test
    func initialStateIsPreserved() {
        let store = FluxStore<TestFeature>(state: .init(count: 42))

        #expect(store.state.count == 42)
    }

    @Test
    func dispatchReducesStateImmediately() {
        let store = FluxStore<TestFeature>(state: .init())

        store.dispatch(.increment)

        #expect(store.state.count == 1)
    }

    @Test
    func repeatedActionsAccumulate() {
        let store = FluxStore<TestFeature>(state: .init())

        store.dispatch(.increment)
        store.dispatch(.increment)
        store.dispatch(.decrement)

        #expect(store.state.count == 1)
    }

    @Test
    func noOpActionPreservesState() {
        let store = FluxStore<TestFeature>(state: .init(count: 42))

        store.dispatch(.load)

        #expect(store.state.count == 42)
    }

    @Test
    func middlewareReceivesActionAndReducedState() async {
        let observations = AsyncStream<(TestFeature.State, TestFeature.Action)>.makeStream()
        defer { observations.continuation.finish() }
        let store = FluxStore<TestFeature>(state: .init(count: 10), middlewares: [
            { state, action in
                observations.continuation.yield((state, action))
                return nil
            }
        ])

        store.dispatch(.increment)

        var iterator = observations.stream.makeAsyncIterator()
        let observation = await iterator.next()
        #expect(observation?.0.count == 11)
        #expect(observation?.1 == .increment)
        #expect(store.state.count == 11)
    }

    @Test
    func returnedActionsAreReducedAndTriggerMiddlewareAgain() async {
        let actions = AsyncStream<TestFeature.Action>.makeStream()
        defer { actions.continuation.finish() }
        let store = FluxStore<TestFeature>(state: .init(), middlewares: [
            { _, action in
                actions.continuation.yield(action)
                switch action {
                case .decrement: return .increment
                case .increment: return .load
                case .load: return nil
                }
            }
        ])

        store.dispatch(.decrement)

        var iterator = actions.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        #expect(first == .decrement)
        #expect(second == .increment)
        #expect(third == .load)
        #expect(store.state.count == 0)
    }

    @Test
    func everyMiddlewareReceivesDispatchedAction() async {
        let observations = AsyncStream<(Int, TestFeature.Action)>.makeStream()
        defer { observations.continuation.finish() }
        let store = FluxStore<TestFeature>(state: .init(), middlewares: [
            { _, action in
                observations.continuation.yield((1, action))
                return nil
            },
            { _, action in
                observations.continuation.yield((2, action))
                return nil
            }
        ])

        store.dispatch(.load)

        var iterator = observations.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        // Middleware completion order is intentionally not part of the contract.
        #expect(Set([first?.0, second?.0]) == Set([1, 2]))
        #expect(first?.1 == .load)
        #expect(second?.1 == .load)
        #expect(store.state.count == 0)
    }

    @Test
    func suspendedMiddlewareDoesNotBlockDispatch() async {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish()
            release.continuation.finish()
            completed.continuation.finish()
        }
        let store = FluxStore<TestFeature>(state: .init(), middlewares: [
            { _, action in
                switch action {
                case .load:
                    var iterator = release.stream.makeAsyncIterator()
                    started.continuation.yield(())
                    _ = await iterator.next()
                    return .decrement
                case .decrement:
                    completed.continuation.yield(())
                    return nil
                case .increment:
                    return nil
                }
            }
        ])

        store.dispatch(.load)
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()

        store.dispatch(.increment)
        #expect(store.state.count == 1)

        release.continuation.yield(())
        var completedIterator = completed.stream.makeAsyncIterator()
        _ = await completedIterator.next()
        #expect(store.state.count == 0)
    }

    @Test
    func statePublisherEmitsInitialStateAndSynchronousChanges() {
        let store = FluxStore<TestFeature>(state: .init(count: 10))
        var counts: [Int] = []
        let subscription = store.$state.sink { counts.append($0.count) }
        defer { subscription.cancel() }

        store.dispatch(.increment)
        store.dispatch(.decrement)

        #expect(counts == [10, 11, 10])
    }

    @Test
    func statePublisherEmitsMiddlewareChanges() async {
        let store = FluxStore<TestFeature>(state: .init(), middlewares: [
            { _, action in action == .decrement ? .increment : nil }
        ])
        let states = AsyncStream<TestFeature.State>.makeStream()
        let subscription = store.$state.sink { states.continuation.yield($0) }
        defer {
            subscription.cancel()
            states.continuation.finish()
        }

        store.dispatch(.decrement)

        var iterator = states.stream.makeAsyncIterator()
        let initial = await iterator.next()
        let dispatched = await iterator.next()
        let returned = await iterator.next()
        #expect(initial?.count == 0)
        #expect(dispatched?.count == -1)
        #expect(returned?.count == 0)
    }

    @Test
    func storesHaveIndependentState() {
        let first = FluxStore<TestFeature>(state: .init())
        let second = FluxStore<TestFeature>(state: .init(count: 10))

        first.dispatch(.increment)
        second.dispatch(.decrement)

        #expect(first.state.count == 1)
        #expect(second.state.count == 9)
    }
}
