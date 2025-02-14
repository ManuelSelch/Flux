import Foundation
import Combine

public protocol Feature {
    associatedtype State
    associatedtype Action: Sendable
}

public typealias StoreOf<F: Feature> = BaseStore<F.State, F.Action>
public typealias Middleware<State, Action> =
    @Sendable (State, Action) async -> (Action?)


open class BaseStore<S, A: Sendable>: ObservableObject {
    public typealias State = S
    public typealias Action = A
    public typealias M = Middleware<S, A>
    
    @Published public private(set) var state: S
    private let stateQueue = DispatchQueue(label: "flux.state.queue", qos: .userInitiated)
    private let middlewares: [M]
    
    var cancellables: Set<AnyCancellable> = []
    
    public init(state: S, middlewares: [M]) {
        self.state = state
        self.middlewares = middlewares
    }
    
    @MainActor
    public func dispatch(_ action: A) {
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

/*
public extension AnyPublisher {
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
        _ operation: @escaping @Sendable () -> (Output?)
    ) -> AnyPublisher<Output, Failure>
    {
        
        return Future { promise in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let result = operation() {
                    promise(.success(result))
                }
            }
        }.eraseToAnyPublisher()
    }
}
*/
