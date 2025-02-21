import Foundation
import Testing
@testable import Flux

@MainActor
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

    public init(state: State, _ feature: F, middlewares: [M]) {
        self.state = state
        self.reduce = feature.reduce
        self.middlewares = middlewares
    }
    
    public func dispatch(_ action: Action) {
        self.reduce(&self.state, action)
        self.recordedActions.append(action)
    
        middlewares.forEach { middleware in
            effects.enter()
            effectCount += 1
            Task {
                guard let action =  middleware(state, action) else {return}
                self.dispatch(action)
                
                defer {
                    effects.leave()
                    effectCount -= 1
                }
            }
        }
    }
    
    private func addEffect(_ effect: Action) {
        self.recordedActions.append(effect)
    }
    
   
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
            let diff =
                debugDiff(oldState, newState)
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
        return
            effects.wait(timeout: DispatchTime.now() + .seconds(5)) == .success
    }
    

    public func finish(
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
    
    public func receive(
        _ action: Action, _ expected: @escaping (inout State) -> (),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        return await receive(
            [action], expected,
            sourceLocation: sourceLocation
        )
    }
    
    
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
            let diff =
                debugDiff(oldState, newState)
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


// MARK: - helper methods
func debugOutput(_ value: Any, indent: Int = 0) -> String {
    var visitedItems: Set<ObjectIdentifier> = []

    func debugOutputHelp(_ value: Any, indent: Int = 0) -> String {
        let mirror = Mirror(reflecting: value)
        switch (value, mirror.displayStyle) {
        case let (value as CustomDebugOutputConvertible, _):
            return value.debugOutput.indent(by: indent)
        case (_, .collection?):
            return """
        [
        \(mirror.children.map { "\(debugOutput($0.value, indent: 2)),\n" }.joined())]
        """
                .indent(by: indent)

        case (_, .dictionary?):
            let pairs = mirror.children.map { label, value -> String in
                let pair = value as! (key: AnyHashable, value: Any)
                return
                    "\("\(debugOutputHelp(pair.key.base)): \(debugOutputHelp(pair.value)),".indent(by: 2))\n"
            }
            return """
        [
        \(pairs.sorted().joined())]
        """
                .indent(by: indent)

        case (_, .set?):
            return """
        Set([
        \(mirror.children.map { "\(debugOutputHelp($0.value, indent: 2)),\n" }.sorted().joined())])
        """
                .indent(by: indent)

        case (_, .optional?):
            return mirror.children.isEmpty
                ? "nil".indent(by: indent)
                : debugOutputHelp(mirror.children.first!.value, indent: indent)

        case (_, .enum?) where !mirror.children.isEmpty:
            let child = mirror.children.first!
            let childMirror = Mirror(reflecting: child.value)
            let elements =
                childMirror.displayStyle != .tuple
                ? debugOutputHelp(child.value, indent: 2)
                : childMirror.children.map { child -> String in
                    let label = child.label!
                    return "\(label.hasPrefix(".") ? "" : "\(label): ")\(debugOutputHelp(child.value))"
                }
                .joined(separator: ",\n")
                .indent(by: 2)
            return """
        \(mirror.subjectType).\(child.label!)(
        \(elements)
        )
        """
                .indent(by: indent)

        case (_, .enum?):
            return """
        \(mirror.subjectType).\(value)
        """
                .indent(by: indent)

        case (_, .struct?) where !mirror.children.isEmpty:
            let elements = mirror.children
                .map { "\($0.label.map { "\($0): " } ?? "")\(debugOutputHelp($0.value))".indent(by: 2) }
                .joined(separator: ",\n")
            return """
        \(mirror.subjectType)(
        \(elements)
        )
        """
                .indent(by: indent)

        case let (value as AnyObject, .class?)
                where !mirror.children.isEmpty && !visitedItems.contains(ObjectIdentifier(value)):
            visitedItems.insert(ObjectIdentifier(value))
            let elements = mirror.children
                .map { "\($0.label.map { "\($0): " } ?? "")\(debugOutputHelp($0.value))".indent(by: 2) }
                .joined(separator: ",\n")
            return """
        \(mirror.subjectType)(
        \(elements)
        )
        """
                .indent(by: indent)

        case let (value as AnyObject, .class?)
                where !mirror.children.isEmpty && visitedItems.contains(ObjectIdentifier(value)):
            return "\(mirror.subjectType)(↩︎)"

        case let (value as CustomStringConvertible, .class?):
            return value.description
                .replacingOccurrences(
                    of: #"^<([^:]+): 0x[^>]+>$"#, with: "$1()", options: .regularExpression
                )
                .indent(by: indent)

        case let (value as CustomDebugStringConvertible, _):
            return value.debugDescription
                .replacingOccurrences(
                    of: #"^<([^:]+): 0x[^>]+>$"#, with: "$1()", options: .regularExpression
                )
                .indent(by: indent)

        case let (value as CustomStringConvertible, _):
            return value.description
                .indent(by: indent)

        case (_, .struct?), (_, .class?):
            return "\(mirror.subjectType)()"
                .indent(by: indent)

        case (_, .tuple?) where mirror.children.isEmpty:
            return "()"
                .indent(by: indent)

        case (_, .tuple?):
            let elements = mirror.children.map { child -> String in
                let label = child.label!
                return "\(label.hasPrefix(".") ? "" : "\(label): ")\(debugOutputHelp(child.value))"
                    .indent(by: 2)
            }
            return """
        (
        \(elements.joined(separator: ",\n"))
        )
        """
                .indent(by: indent)

        case (_, nil):
            return "\(value)"
                .indent(by: indent)

        @unknown default:
            return "\(value)"
                .indent(by: indent)
        }
    }

    return debugOutputHelp(value, indent: indent)
}

func debugDiff<T>(_ before: T, _ after: T, printer: (T) -> String = { debugOutput($0) }) -> String? {
    diff(printer(before), printer(after))
}

extension String {
    func indent(by indent: Int) -> String {
        let indentation = String(repeating: " ", count: indent)
        return indentation + self.replacingOccurrences(of: "\n", with: "\n\(indentation)")
    }
}

public protocol CustomDebugOutputConvertible {
    var debugOutput: String { get }
}


extension URL: CustomDebugOutputConvertible {
    public var debugOutput: String {
        self.absoluteString
    }
}


func diff(_ first: String, _ second: String) -> String? {
    struct Difference {
        enum Which {
            case both
            case first
            case second

            var prefix: StaticString {
                switch self {
                case .both: return "\u{2007}"
                case .first: return "−"
                case .second: return "+"
                }
            }
        }

        let elements: ArraySlice<Substring>
        let which: Which
    }

    func diffHelp(_ first: ArraySlice<Substring>, _ second: ArraySlice<Substring>) -> [Difference] {
        var indicesForLine: [Substring: [Int]] = [:]
        for (firstIndex, firstLine) in zip(first.indices, first) {
            indicesForLine[firstLine, default: []].append(firstIndex)
        }

        var overlap: [Int: Int] = [:]
        var firstIndex = first.startIndex
        var secondIndex = second.startIndex
        var count = 0

        for (index, secondLine) in zip(second.indices, second) {
            var innerOverlap: [Int: Int] = [:]
            var innerFirstIndex = firstIndex
            var innerSecondIndex = secondIndex
            var innerCount = count

            indicesForLine[secondLine]?.forEach { firstIndex in
                let newCount = (overlap[firstIndex - 1] ?? 0) + 1
                innerOverlap[firstIndex] = newCount
                if newCount > count {
                    innerFirstIndex = firstIndex - newCount + 1
                    innerSecondIndex = index - newCount + 1
                    innerCount = newCount
                }
            }

            overlap = innerOverlap
            firstIndex = innerFirstIndex
            secondIndex = innerSecondIndex
            count = innerCount
        }

        //swiftlint:disable empty_count
        if count == 0 {
            var differences: [Difference] = []
            if !first.isEmpty { differences.append(Difference(elements: first, which: .first)) }
            if !second.isEmpty { differences.append(Difference(elements: second, which: .second)) }
            return differences
        } else {
            var differences = diffHelp(first.prefix(upTo: firstIndex), second.prefix(upTo: secondIndex))
            differences.append(
                Difference(elements: first.suffix(from: firstIndex).prefix(count), which: .both))
            differences.append(
                contentsOf: diffHelp(
                    first.suffix(from: firstIndex + count), second.suffix(from: secondIndex + count)))
            return differences
        }
    }

    let differences = diffHelp(
        first.split(separator: "\n", omittingEmptySubsequences: false)[...],
        second.split(separator: "\n", omittingEmptySubsequences: false)[...]
    )
    if differences.count == 1, case .both = differences[0].which { return nil }
    var string = differences.reduce(into: "") { string, diff in
        diff.elements.forEach { line in
            string += "\(diff.which.prefix) \(line)\n"
        }
    }
    string.removeLast()
    return string
}

