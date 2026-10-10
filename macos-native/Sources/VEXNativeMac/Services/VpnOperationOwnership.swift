import Foundation

// A late operation may release only the busy state that it acquired.
struct VpnOperationOwnership {
    private var owner: UUID?

    var currentOwner: UUID? { owner }

    mutating func begin() -> UUID {
        let next = UUID()
        owner = next
        return next
    }

    func owns(_ candidate: UUID) -> Bool { owner == candidate }

    @discardableResult
    mutating func finish(_ candidate: UUID) -> Bool {
        guard owns(candidate) else { return false }
        owner = nil
        return true
    }

    mutating func invalidate() { owner = nil }
}
