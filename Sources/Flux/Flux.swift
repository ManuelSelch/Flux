import Foundation
import Combine

public protocol Feature {
    associatedtype State
    associatedtype Action
}

public typealias StoreOf<F: Feature> = BaseStore<F.State, F.Action>
public typealias Middleware2<State, Action> = (State, Action) -> AnyPublisher<Action, Never>
public typealias Middleware<State, Action> = @Sendable (State, Action, @escaping @Sendable (Action) -> ()) -> ()


open class BaseStore<S, A: Sendable>: ObservableObject, @unchecked Sendable {
    public typealias State = S
    public typealias Action = A
    public typealias M = Middleware<S, A>
    
    @Published public private(set) var state: S
    private let stateQueue = DispatchQueue(label: "flux.state.queue", qos: .userInitiated)
    private let middlewares: [Flux.Middleware<S, A>]
    private let middlewares2: [Flux.Middleware2<S, A>] = []
    
    var cancellables: Set<AnyCancellable> = []
    
    public init(state: S, middlewares: [Flux.Middleware<S, A>]) {
        self.state = state
        self.middlewares = middlewares
    }
    
    public func dispatch(_ action: A) {
        for middleware in self.middlewares {
            middleware(self.state, action) { @Sendable action in
                Task { @MainActor [self] in
                    self.dispatch(action)
                }
            }
        }

        self.reduce(&self.state, action)
    }
    
    open func reduce(_ state: inout S, _ action: A) {
        
    }
}


/*
public extension AnyPublisher where Output: Sendable {
    static func dispatch(_ action: Output) -> AnyPublisher<Output, Failure> {
        return Just(action)
            .setFailureType(to: Failure.self)
            .eraseToAnyPublisher()
    }
    
    static func merge(_ publishers: [AnyPublisher<Output, Failure>]) -> AnyPublisher<Output, Failure> {
        return Publishers.MergeMany(publishers)
            .eraseToAnyPublisher()
    }
    
    static var none: AnyPublisher<Output, Failure> {
        Empty()
            .setFailureType(to: Failure.self)
            .eraseToAnyPublisher()
    }
    
    static func run(
        _ operation: @escaping (
            @Sendable (Output) -> Void
        ) async -> Void
    ) -> AnyPublisher<Output, Failure>
    {
        return Future<Output, Failure> { promise in
     
            nonisolated(unsafe) let promise = promise
            
            Task { @MainActor [promise] in
                await operation {
                    promise(.success($0))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    static func call(
        _ operation: @escaping (
            @Sendable (Output) -> Void
        ) async -> Void
    ) -> AnyPublisher<Output, Failure> {
        return Future { promise in

            // Copy promise to a local property to make it nonisolated(unsafe):
            nonisolated(unsafe) let promise = promise

            Task { @MainActor [promise] in
                // Now capture promise in a Sendable closure.
                
                operation {
                    promise(.success($0))
                }
            }
        }.eraseToAnyPublisher()
    }
}
*/
