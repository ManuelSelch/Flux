import Foundation
import Testing
@testable import Flux
import FluxTestStore

struct TestFeature: Feature {
    enum Action: Equatable, Sendable {
        case increment
        case decrement
        case load
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

class FluxTests {
    let store: TestStore<TestFeature>
    
    init() {
        store = TestStore<TestFeature>(state: .init(), middlewares: [myMiddleware])
    }
    
    deinit {
        store.tearDown()
    }
    
    @Test
    @MainActor
    func actionIsReduced_onDispatch() async {
        store.dispatch(.increment) { $0.count = 1 }
        store.dispatch(.increment) { $0.count = 2 }
    }
    
    @Test
    @MainActor
    func effectIsTriggered_onDispatch() async {
        store.dispatch(.decrement) { $0.count = -1 }
        
        await store.receive(.increment) {
            $0.count = 0
        }
    }
}
