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
    return .none
}

@MainActor
struct FluxTests {
    var store: TestStore<TestFeature>
    
    init() {
        self.store = .init(state: .init(), middlewares: [myMiddleware])
    }
    
    @Test
    func onDispatch_actionReduced() {
        store.dispatch(.increment) { $0.count = 1 }
        store.dispatch(.increment) { $0.count = 2 }
        
        store.tearDown()
    }
}
