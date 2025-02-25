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
    enum Action: Equatable, Sendable {
        case increment
        case decrement
    }
    
    struct State: Equatable, Sendable {
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
