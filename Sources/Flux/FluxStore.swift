import Foundation
import Combine

public protocol Feature {
    associatedtype State: Equatable
    associatedtype Action: Sendable & Equatable
}

public typealias StoreOf<F: Feature> = FluxStore<F.State, F.Action>
public typealias Middleware<State, Action> =
    @Sendable (State, Action) async -> (Action?)


open class FluxStore<S: Equatable, A: Sendable>: ObservableObject {
    public typealias State = S
    public typealias Action = A
    public typealias M = Middleware<S, A>
    
    @Published public private(set) var state: S
    internal var middlewares: [M]


    public init(state: S, middlewares: [M]) {
        self.state = state
        self.middlewares = middlewares
    }
    
    @MainActor
    public func dispatch(_ action: A) {
        print("dispatch \(action)")
        self.reduce(&self.state, action)
    
        middlewares.forEach { middleware in
            Task {
                guard let action = await middleware(state, action) else { return }
                
                Task { @MainActor [self] in
                    self.dispatch(action)
                }
            }
        }
    }
    
    
    
    open func reduce(_ state: inout S, _ action: A) {
        
    }
}

