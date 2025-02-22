import Foundation
import Testing
@testable import Flux

public class TestStore<F: Feature> {
    public typealias State = F.State
    public typealias Action = F.Action
    public typealias M = Middleware<F>
    
    public private(set) var state: State
    internal var reduce: (inout State, Action) -> ()
    internal var middlewares: [M] = []
    
    private var recordedActions: [Action] = []
    
    private let effects = DispatchGroup()
    private var effectCount = 0
    private var isEffects = false

    public init(state: F.State, middlewares: [M] = []) {
        self.state = state
        self.reduce = F().reduce
        self.middlewares = middlewares
        
        self.effects.notify(queue: .main) {
            self.isEffects = false
        }
    }
    
    @MainActor
    public func dispatch(_ action: Action) {
        self.reduce(&self.state, action)
        self.recordedActions.append(action)
    
        middlewares.forEach { middleware in
            enterEffect()
            
            Task {
                let effect = await middleware(state, action)
                if let effect = effect {
                    dispatch(effect)
                }
                
                self.leaveEffect()
            }
        }
    }
    
    private func enterEffect() {
        effects.enter()
        effectCount += 1
        isEffects = true
    }
    
    private func leaveEffect() {
        effects.leave()
        effectCount -= 1
    }
    
    private func addEffect(_ effect: Action) {
        self.recordedActions.append(effect)
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
    
    
    func isEffectsDone() -> Bool {
        if(!isEffects) {
            return true
        }
        
        return
            effects.wait(timeout: DispatchTime.now() + .seconds(5)) == .success
    }
    

    public func tearDown(
        file: StaticString = #file, line: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        
        
        let effectsDone = isEffectsDone()
        
        if(!effectsDone) {
            Issue.record(
                """
                unhandles effects: some effects are still running
                \(effectCount)
                """,
                sourceLocation: sourceLocation
            )
        }
        
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
            self.recordedActions.contains(actions)
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
        let startTime = Date()

        while !condition() {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= timeout {
                return false
            }
            try? await Task.sleep(nanoseconds: 500_000_00)
        }
        
        return true
    }
}
