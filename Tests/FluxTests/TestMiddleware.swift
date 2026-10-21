import Flux

/// Test-only closure adapter; production clients implement Middleware directly.
@MainActor
struct TestMiddleware<F: Feature>: Middleware {
    let operation: @MainActor (F.State, F.Action) async -> F.Action?

    init(_ operation: @escaping @MainActor (F.State, F.Action) async -> F.Action?) {
        self.operation = operation
    }

    func handle(_ state: F.State, _ action: F.Action) async -> F.Action? {
        await operation(state, action)
    }
}
