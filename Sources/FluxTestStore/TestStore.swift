import Foundation
import Testing
@testable import Flux

@MainActor
public class TestStore<F: Feature> {
    public typealias State = F.State
    public typealias Action = F.Action
    public typealias M = Middleware<F>
    
    public private(set) var state: State
    internal var middlewares: [M] = []
    
    private var recordedActions: [Action] = []
    
    private var effectTasks: [UUID: Task<Void, Never>] = [:]

    public init(state: F.State, middlewares: [M] = []) {
        self.state = state
        self.middlewares = middlewares
    }
    
    @MainActor
    public func dispatch(_ action: Action) {
        F().reduce(&self.state, action)
        self.recordedActions.append(action)
    
        middlewares.forEach { middleware in
            let id = UUID()
            effectTasks[id] = Task {
                defer { self.effectTasks[id] = nil }
                let effect = await middleware(state, action)
                guard !Task.isCancelled, let effect else { return }
                dispatch(effect)
            }
        }
    }
    
   
    @MainActor
    public func dispatch(
        _ action: Action,
        _ expected: @escaping (inout State) -> (),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if(!self.recordedActions.isEmpty) {
            Issue.record(
              """
              Unhandled actions. You must handle received actions before sending next action:
              \(self.recordedActions)
              """,
              sourceLocation: sourceLocation
            )
        }
        
        var oldState = self.state
        dispatch(action)
        recordedActions.removeFirst()
        let newState = self.state
        
        expected(&oldState)
        
        if oldState != newState {
            let diff = Logger.debugDiff(oldState, newState)
                .map { "\($0.indent(by: 4))\n\n(Expected: −, Actual: +)" }
                ?? """
                Expected:
                \(String(describing: oldState).indent(by: 2))
                Actual:
                \(String(describing: newState).indent(by: 2))
                """
            
            Issue.record(
              """
              State change does not match expectation: …
              \(diff)
              """,
              sourceLocation: sourceLocation
            )
        }
                
    }
    
    
    /// Wait for all middleware, including follow-up tasks, without blocking the main actor.
    /// Receive expected actions before finishing. On timeout/cancellation, report pending
    /// work and request its cancellation; cancellation-ignoring middleware cannot be forced to stop.
    public func finish(
        timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let completed = await waitUntil(condition: { self.effectTasks.isEmpty }, timeout: timeout)
        if !completed {
            let count = effectTasks.count
            for task in effectTasks.values { task.cancel() }
            Issue.record(
                "Timed out or cancelled while finishing: \(count) middleware task(s) still running.",
                sourceLocation: sourceLocation
            )
        }
        assertNoRecordedActions(sourceLocation: sourceLocation)
    }

    /// Nonblocking safety check, not a replacement for awaiting finish().
    public func tearDown(
        file: StaticString = #file, line: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if !effectTasks.isEmpty {
            Issue.record(
                "Unhandled effects: \(effectTasks.count) middleware task(s) still running. Await finish() before teardown.",
                sourceLocation: sourceLocation
            )
        }
        assertNoRecordedActions(sourceLocation: sourceLocation)
    }

    private func assertNoRecordedActions(sourceLocation: SourceLocation) {
        if(recordedActions.count > 0) {
            Issue.record(
                """
                unhandled actions before finishing test:
                \(recordedActions)
                """,
                sourceLocation: sourceLocation
            )
        }
    }
    
    @MainActor
    public func receive(
        _ action: Action, _ expected: @escaping (inout State) -> (),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        return await receive(
            [action], expected,
            sourceLocation: sourceLocation
        )
    }
    
    
    @MainActor
    public func receive(
        _ actions: [Action], _ expected: @escaping (inout State) -> (),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var oldState = self.state
        
        let success = await waitUntil {
            if #available(iOS 16.0, *) {
                return self.recordedActions.contains(actions)
            } else {
                return actions.allSatisfy { a in self.recordedActions.contains(where: {$0 == a}) }
            }
        }
        
        if(!success) {
            Issue.record(
               """
               timeout waiting for action
               \(recordedActions)
               """,
               sourceLocation: sourceLocation
           )
            return
        }
        
        if(recordedActions.count != actions.count) {
            Issue.record(
                """
                unhandled actions before this action:
                \(recordedActions)
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        recordedActions.removeAll()
        
        let newState = self.state
        expected(&oldState)
        
        
        if oldState != newState {
            let diff = Logger.debugDiff(oldState, newState)
                .map { "\($0.indent(by: 4))\n\n(Expected: −, Actual: +)" }
                ?? """
                Expected:
                \(String(describing: oldState).indent(by: 2))
                Actual:
                \(String(describing: newState).indent(by: 2))
                """

            Issue.record(
              """
              State change does not match expectation: …
              \(diff)
              """,
              sourceLocation: sourceLocation
            )
        }

    }
    
    @MainActor
    func waitUntil(condition: @escaping () -> Bool, timeout: TimeInterval = 1.0) async -> Bool {
        let startTime = ProcessInfo.processInfo.systemUptime

        while !condition() {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime - startTime >= timeout {
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                return false
            }
        }
        
        return true
    }
}
