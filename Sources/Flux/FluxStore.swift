import Foundation
import Combine

public protocol Feature {
    associatedtype State: Equatable & Sendable
    associatedtype Action: Sendable & Equatable
    
    init()
    
    @MainActor
    func reduce(_ state: inout State, _ action: Action)
}

/// A post-reducer effect handler. Different invocations may overlap at suspension points.
@MainActor
public protocol Middleware<F> {
    associatedtype F: Feature

    /// Called once per store construction. Retain the handle, not the concrete store.
    /// Configure subscriptions here; dispatch feature lifecycle actions after construction.
    func initialize(_ store: StoreHandle<F>)

    /// Receives the snapshot captured immediately after this action was reduced.
    /// Return a follow-up action, or use the handle to dispatch intermediate/stream updates.
    func after(_ state: F.State, _ action: F.Action) async -> F.Action?
}

public extension Middleware {
    func initialize(_ store: StoreHandle<F>) {}
}

/// Restricted store access that middleware may retain strongly without retaining the store.
@MainActor
public final class StoreHandle<F: Feature> {
    private let readState: @MainActor () -> F.State?
    private let send: @MainActor (F.Action) -> Void

    internal convenience init(_ store: FluxStore<F>) {
        self.init(
            getState: { [weak store] in store?.state },
            dispatch: { [weak store] in store?.dispatch($0) }
        )
    }

    // Only the companion test-store module constructs assertion-aware handles.
    package init(
        getState: @escaping @MainActor () -> F.State?,
        dispatch: @escaping @MainActor (F.Action) -> Void
    ) {
        self.readState = getState
        self.send = dispatch
    }

    /// The current state, or nil if the owning store has been released.
    public func getState() -> F.State? {
        readState()
    }

    /// Reduces synchronously. Does nothing if the owning store has been released.
    public func dispatch(_ action: F.Action) {
        send(action)
    }
}

@MainActor
public class FluxStore<F: Feature>: ObservableObject {
    public typealias State = F.State
    public typealias Action = F.Action
    public typealias M = any Middleware<F>
    
    @Published public private(set) var state: State
    internal var reduce: (inout State, Action) -> ()
    internal var middlewares: [M]


    public init(state: F.State, middlewares: [M] = []) {
        self.state = state
        self.reduce = F().reduce
        self.middlewares = middlewares

        let handle = StoreHandle(self)
        middlewares.forEach { middleware in
            middleware.initialize(handle)
        }
    }
    
    public func dispatch(_ action: Action) {
        self.reduce(&self.state, action)

        let snapshot = state
    
        middlewares.forEach { middleware in
            Task { [weak self] in
                guard !Task.isCancelled else { return }
                let response = await middleware.after(snapshot, action)
                guard !Task.isCancelled, let response else { return }
                self?.dispatch(response)
            }
        }
    }
}

