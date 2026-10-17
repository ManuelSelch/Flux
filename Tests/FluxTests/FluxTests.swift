import Foundation
import Testing
@testable import Flux
import FluxTestStore

struct TestFeature: Feature {
    nonisolated enum Action: Equatable, Sendable {
        case increment
        case decrement
        case load
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
        case .load:
            break
        }
    }
}

let myMiddleware: Middleware<TestFeature> = { state, action in
    switch(action) {
    case .decrement:
        return .increment
    default:
        return .none
    }
}

@MainActor
struct FluxTests {
    @Test
    func actionIsReduced_onDispatch() async {
        let store = TestStore<TestFeature>(state: .init(), middlewares: [myMiddleware])
        store.dispatch(.increment) { $0.count = 1 }
        store.dispatch(.increment) { $0.count = 2 }
        await store.finish()
    }

    @Test
    func effectIsTriggered_onDispatch() async {
        let store = TestStore<TestFeature>(state: .init(), middlewares: [myMiddleware])
        store.dispatch(.decrement) { $0.count = -1 }

        await store.receive(.increment) {
            $0.count = 0
        }
        await store.finish()
    }
}
