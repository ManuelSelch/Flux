# Flux for SwiftUI

A lightweight, main-actor-isolated Flux store with synchronous reducers,
asynchronous middleware, and assertion-driven tests.

## Installation

Add the package to your Xcode project or Swift package. The examples below target
the **upcoming 2.0 middleware API**; the release must be published before using
this version requirement:

```swift
dependencies: [
    .package(url: "https://github.com/ManuelSelch/Flux.git", from: "2.0.0")
]
```

Products: `Flux` and `FluxTestStore`.

## Feature and store

A feature defines its state, actions, and synchronous reducer. State and actions
must be `Equatable` and `Sendable`.

```swift
import Flux

struct CounterFeature: Feature {
    struct State: Equatable, Sendable {
        var count = 0
        var error: String?
    }

    enum Action: Equatable, Sendable {
        case increment
        case load
        case loaded(Int)
        case loadFailed(String)
    }

    @MainActor
    func reduce(_ state: inout State, _ action: Action) {
        switch action {
        case .increment:
            state.count += 1
        case .load:
            state.error = nil
        case .loaded(let count):
            state.count = count
        case .loadFailed(let message):
            state.error = message
        }
    }
}

@MainActor
func makeStore() -> FluxStore<CounterFeature> {
    FluxStore(state: .init())
}
```

Observe `store.state` in SwiftUI with `@ObservedObject` or `@StateObject`.
`store.dispatch(.increment)` reduces immediately and publishes the new state.

## Middleware

Implement `Middleware` instead of supplying a closure. Its methods are
`@MainActor` isolated. `handle` runs asynchronously after reduction and may return
one follow-up action; return `nil` when no follow-up is needed.

```swift
struct CounterMiddleware: Middleware {
    typealias F = CounterFeature

    let loadCount: @Sendable () async throws -> Int

    func handle(_ state: F.State, _ action: F.Action) async -> F.Action? {
        guard case .load = action else { return nil }

        do {
            return .loaded(try await loadCount())
        } catch is CancellationError {
            return nil
        } catch {
            return .loadFailed(error.localizedDescription)
        }
    }
}

@MainActor
func makeLoadingStore() -> FluxStore<CounterFeature> {
    FluxStore(
        state: .init(),
        middlewares: [CounterMiddleware(loadCount: { 42 })]
    )
}
```

### Initialization and store access

`initialize(_ store: StoreHandle<F>)` has a public default no-op implementation.
Simple middleware does not need to implement it.

The store calls it once per middleware entry during construction, before any
scheduled `handle` invocations. Use a fresh stateful middleware instance per
store. Initialize dependencies/subscriptions here; dispatch application lifecycle
actions after store construction, rather than synchronously during initialization.

A `StoreHandle` exposes only:

- `getState() -> F.State?`: the **current** state, or nil after store release.
- `dispatch(_:)`: synchronously reduces an action; no-op after store release.

You may retain this handle strongly: its internal closures capture the store
weakly. The concrete store is never exposed to middleware.

For example, a middleware can observe an external stream and emit multiple actions:

```swift
@MainActor
final class CounterUpdatesMiddleware: Middleware {
    typealias F = CounterFeature

    private let updates: AsyncStream<Int>
    private var observation: Task<Void, Never>?

    init(updates: AsyncStream<Int>) {
        self.updates = updates
    }

    func initialize(_ store: StoreHandle<F>) {
        let updates = updates
        observation = Task {
            for await count in updates {
                guard !Task.isCancelled else { return }
                store.dispatch(.loaded(count))
            }
        }
    }

    func handle(_ state: F.State, _ action: F.Action) async -> F.Action? {
        nil
    }

    func stopObserving() async {
        observation?.cancel()
        await observation?.value
        observation = nil
    }

    deinit {
        observation?.cancel()
    }
}
```

The middleware or its owning feature must explicitly stop subscriptions when
appropriate. A connection-oriented middleware would normally start/stop them in
response to connect/disconnect actions instead.

### Execution contract

1. `dispatch` reduces synchronously.
2. The store immediately captures the post-reducer state.
3. Each middleware runs in an independent task with that snapshot and action.
4. Any non-nil returned action is dispatched through the store again.

- Dispatch does not await middleware completion. Middleware invocations may
  overlap; there is no middleware start/completion-order guarantee.
- `nil` never swallows the original action or prevents another middleware running.
- `getState()` reads live state, unlike the supplied snapshot. Calling handle
  `dispatch` then `getState` without suspension sees that reduction, but does not
  await the resulting middleware.
- Work between suspension points still runs on the main actor. Move expensive
  blocking work off that actor; `async` alone does not make it background work.
- Sequence dependent operations explicitly, using result actions or
  middleware-owned coordination, not registration order.
- Middleware tasks do not keep the owning store alive. Returned actions are
  discarded if the store has been released or the task is cancelled.
- Weak ownership is not automatic cancellation. Middleware owns subscriptions,
  resource disposal, and any additional tasks it creates.

## Tests

`TestStore` uses the same middleware initialization, handle access, post-reducer
snapshots, and follow-up dispatch behavior. Actions dispatched through a handle
are recorded just like returned actions.

```swift
import Testing
import Flux
import FluxTestStore

@MainActor
struct CounterTests {
    @Test
    func incrementsImmediately() async {
        let store = TestStore<CounterFeature>(state: .init())
        defer { store.tearDown() }

        store.dispatch(.increment) { $0.count = 1 }
        await store.finish()
    }

    @Test
    func loadsThroughMiddleware() async {
        let store = TestStore<CounterFeature>(
            state: .init(),
            middlewares: [CounterMiddleware(loadCount: { 42 })]
        )
        defer { store.tearDown() }

        store.dispatch(.load) { _ in }
        await store.receive(.loaded(42)) { $0.count = 42 }
        await store.finish()
    }
}
```

Receive expected actions before calling `await store.finish()`. It asynchronously
waits for store-scheduled middleware tasks, including recursively dispatched
follow-up work, and reports unreceived actions. Default timeout: five seconds;
override with `await store.finish(timeout: 10)`.

On timeout or cancellation, remaining tasks are reported and cancellation is
requested. Cancellation is cooperative; returned actions from cancelled tasks
are suppressed. Middleware-owned stream tasks are **not** tracked by `finish()`:
stop and await those separately. Middleware that dispatches directly should
check cancellation before emitting results after suspended work.

`store.tearDown()` is a nonblocking assertion check. It does not wait for or cancel
work and cannot replace `finish()`.

## Migrating from 1.x

This is a breaking middleware API change; there is no legacy closure overload.

- Replace middleware closures with types conforming to `Middleware`.
- Declare `typealias F = YourFeature`.
- Move the closure body into `handle(_ state: F.State, _ action: F.Action) async -> F.Action?`.
- Keep returning optional actions for ordinary request/result operations.
- Optionally implement `initialize(_ store: StoreHandle<F>)` for live state access,
  intermediate dispatches, or subscriptions.
- Use `any Middleware<YourFeature>` when storing heterogeneous middleware.
- Make stateful middleware main-actor isolated and create a fresh instance per store.
- Reducer and TestStore dispatch/receive/finish usage remain unchanged.

## Verification

Run `swift test` and `swift test -c release` from the package directory.
