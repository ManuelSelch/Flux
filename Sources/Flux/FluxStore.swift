import Foundation
import Combine

public protocol Feature {
    associatedtype State: Equatable & Sendable
    associatedtype Action: Sendable & Equatable
    
    init()
    func reduce(_ state: inout State, _ action: Action)
}

public typealias Middleware<F: Feature> =
    @Sendable (F.State, F.Action) async -> (F.Action?)

@MainActor
public class FluxStore<F: Feature>: ObservableObject {
    public typealias State = F.State
    public typealias Action = F.Action
    public typealias M = Middleware<F>
    
    @Published public private(set) var state: State
    internal var reduce: (inout State, Action) -> ()
    internal var middlewares: [M]


    public init(state: F.State, middlewares: [M] = []) {
        self.state = state
        self.reduce = F().reduce
        self.middlewares = middlewares
    }
    
    public func dispatch(_ action: Action) {
        self.reduce(&self.state, action)
    
        middlewares.forEach { middleware in
            Task {
                guard let action = await middleware(state, action) else {return}
                self.dispatch(action)
            }
        }
    }
}

