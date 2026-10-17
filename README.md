# Flux for SwiftUI

this package is a lightweight Flux-based state management library for Swift applications. 
It provides a unidirectional data flow architecture, making state management predictable and scalable.

## Features

- **Unidirectional Data Flow** – Ensures a single source of truth for application state.  
- **Modular & Scalable** – Easily extendable for complex applications.  
- **Type-Safe State Management** – Uses Swift’s strong typing for reliable state updates.  
- **Lightweight & Efficient** – Minimal boilerplate 

## Installation

### Swift Package Manager (SPM)

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/manuelselch/Flux.git", from: "1.0.0")
]
```

## Getting Started
### Simple feature without side effects
- dispatch an action
- reduce it to change the state

```swift
import Flux

struct CounterFeature: Feature {
    nonisolated enum Action: Equatable, Sendable {
        case increment
        case decrement
    }
    
    nonisolated struct State: Equatable, Sendable {
        var count = 0
    }
    
    func reduce(_ state: inout State, _ action: Action) {
        switch(action) {
        case .increment:
            state.count += 1
        case .decrement:
            state.count -= 1
        }
    }
}
```

### Side effects
- dispatch an action
- trigger a middleware
- do async stuff
- send a new effect / action

```swift
let myMiddleware: Middleware<TestFeature> = { state, action in
    switch(action) {
    case .decrement:
        // async operation...
        sleep(3)
        // effect
        return .increment


    default:
        return .none
    }
}
```

## Unit Tests

`TestStore` is main-actor isolated. Create one store per test, receive expected
responses, then call `await store.finish()` before the test returns. `finish()`
waits asynchronously for all middleware tasks, including follow-up work, and
reports any unreceived actions. Its default timeout is five seconds; use
`await store.finish(timeout: 10)` when a test intentionally needs longer.

On timeout or cancellation, pending tasks are reported and cancellation is
requested. Middleware must cooperate with cancellation to stop; Swift cannot
forcibly terminate work that ignores it. Cancelled middleware responses are not
dispatched.

`store.tearDown()` is a **nonblocking assertion check**. It may be used as a final
safety check, but it does not wait for or cancel work and cannot replace `finish()`.

### test feature without side effects
- dispatch an action and compare expected and received state
- FluxTestStore checks all state changes

```swift
import FluxTestStore

@MainActor
struct CounterTests {
    @Test
    func counterIsIncremented_onIncrement() async {
        let store = TestStore<CounterFeature>(state: .init())
        defer { store.tearDown() }

        store.dispatch(.increment) { $0.count = 1 }
        store.dispatch(.increment) { $0.count = 2 }
        await store.finish()
    }

    @Test
    func counterIsDecremented_onDecrement() async {
        let store = TestStore<CounterFeature>(state: .init())
        defer { store.tearDown() }

        store.dispatch(.decrement) { $0.count = -1 }
        store.dispatch(.decrement) { $0.count = -2 }
        await store.finish()
    }
}
```

### test side effects
- FluxTestStore detects running side effects
- and gives an error if some effects are not handles

```swift
    @Test
    @MainActor
    func counterWillBeIncremented_onDecrement() async {
        store.dispatch(.decrement) { $0.count = -1 }
        await store.receive(.increment) { $0.count = 0 }
        await store.finish()
    }
```
