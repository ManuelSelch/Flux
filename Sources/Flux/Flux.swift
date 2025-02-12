import Foundation

public struct Flux {
    public protocol Feature {
        associatedtype State
        associatedtype Action
    }
    
    public typealias StoreOf<F: Feature> = BaseStore<F.State, F.Action>
    
    
    public typealias Middleware<State, Action> = (State, Action, @escaping (Action) -> ()) -> ()
}

public class BaseStore<S, A>: ObservableObject {
    @Published public private(set) var state: S
    private let stateQueue = DispatchQueue(label: "flux.state.queue", qos: .userInitiated)
    private let middlewares: [Flux.Middleware<S, A>]
    
    init(state: S, middlewares: [Flux.Middleware<S, A>]) {
        self.state = state
        self.middlewares = middlewares
    }
    
    public func dispatch(_ action: A) {
        for middleware in self.middlewares {
            middleware(self.state, action) { newAction in
                self.dispatch(newAction)
            }
        }

        stateQueue.sync {
            self.reduce(&self.state, action)
        }
    }
    
    func reduce(_ state: inout S, _ action: A) {
        
    }
}

