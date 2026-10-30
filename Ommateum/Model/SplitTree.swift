import Foundation

/// The direction in which a split node lays out its children.
enum SplitAxis: String, Codable, Sendable {
    /// Children are placed side by side (left → right).
    case horizontal
    /// Children are stacked (top → bottom).
    case vertical
}

/// The edge of a pane on which a new pane is created when a tab is dropped there.
enum PaneEdge: String, Codable, Sendable {
    case left, right, top, bottom

    var axis: SplitAxis { (self == .left || self == .right) ? .horizontal : .vertical }
    /// Whether the new pane goes before the target in the split order.
    var isLeading: Bool { self == .left || self == .top }
}

/// Recursive layout of panes in a window. Leaves hold pane IDs; the pane contents live elsewhere.
///
/// All mutating helpers return normalized trees:
/// - a split never has fewer than two children,
/// - a split never directly contains a split of the same axis (it is flattened),
/// - `fractions` always matches the number of children and sums to 1.
indirect enum SplitTree: Equatable, Sendable {
    case leaf(UUID)
    case split(SplitAxis, [SplitTree], [Double])

    // MARK: Queries

    var leaves: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, let children, _): children.flatMap(\.leaves)
        }
    }

    func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    // MARK: Mutations

    /// Splits the leaf `target` and places `newLeaf` on `edge` of it. The two share the target's former space equally.
    func inserting(_ newLeaf: UUID, at edge: PaneEdge, of target: UUID) -> SplitTree {
        transformLeaf(target) { leaf in
            let pair: [SplitTree] = edge.isLeading ? [.leaf(newLeaf), leaf] : [leaf, .leaf(newLeaf)]
            return .split(edge.axis, pair, [0.5, 0.5])
        }.normalized()
    }

    /// Removes the leaf `id`. Returns `nil` when the tree would become empty.
    func removing(_ id: UUID) -> SplitTree? {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? nil : self
        case .split(let axis, let children, let fractions):
            var kept: [SplitTree] = []
            var keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let newChild = child.removing(id) {
                    kept.append(newChild)
                    keptFractions.append(fraction)
                }
            }
            if kept.isEmpty { return nil }
            return SplitTree.split(axis, kept, keptFractions).normalized()
        }
    }

    /// Replaces the fractions of the split found by following `path` (child indices from the root).
    func settingFractions(_ newFractions: [Double], at path: [Int]) -> SplitTree {
        guard case .split(let axis, var children, let fractions) = self else { return self }
        guard let first = path.first else {
            guard newFractions.count == children.count else { return self }
            return .split(axis, children, Self.normalize(newFractions))
        }
        guard children.indices.contains(first) else { return self }
        children[first] = children[first].settingFractions(newFractions, at: Array(path.dropFirst()))
        return .split(axis, children, fractions)
    }

    /// Restores the structural invariants described on the type.
    func normalized() -> SplitTree {
        guard case .split(let axis, let children, let fractions) = self else { return self }
        var flatChildren: [SplitTree] = []
        var flatFractions: [Double] = []
        let base = Self.normalize(fractions.count == children.count ? fractions : Array(repeating: 1, count: children.count))
        for (child, fraction) in zip(children.map { $0.normalized() }, base) {
            if case .split(let childAxis, let grandChildren, let childFractions) = child, childAxis == axis {
                flatChildren.append(contentsOf: grandChildren)
                flatFractions.append(contentsOf: childFractions.map { $0 * fraction })
            } else {
                flatChildren.append(child)
                flatFractions.append(fraction)
            }
        }
        switch flatChildren.count {
        case 0: return self // unreachable for well-formed input; keep as is
        case 1: return flatChildren[0]
        default: return .split(axis, flatChildren, Self.normalize(flatFractions))
        }
    }

    // MARK: Helpers

    private func transformLeaf(_ id: UUID, _ transform: (SplitTree) -> SplitTree) -> SplitTree {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? transform(self) : self
        case .split(let axis, let children, let fractions):
            return .split(axis, children.map { $0.transformLeaf(id, transform) }, fractions)
        }
    }

    static func normalize(_ values: [Double]) -> [Double] {
        let clamped = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let sum = clamped.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1 / Double(max(values.count, 1)), count: values.count) }
        return clamped.map { $0 / sum }
    }
}

// MARK: - Codable

extension SplitTree: Codable {
    private enum CodingKeys: String, CodingKey { case pane, axis, children, fractions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try container.decodeIfPresent(UUID.self, forKey: .pane) {
            self = .leaf(pane)
            return
        }
        let axis = try container.decode(SplitAxis.self, forKey: .axis)
        let children = try container.decode([SplitTree].self, forKey: .children)
        let fractions = try container.decodeIfPresent([Double].self, forKey: .fractions) ?? []
        guard !children.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .children, in: container, debugDescription: "split without children")
        }
        self = SplitTree.split(axis, children, fractions).normalized()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try container.encode(id, forKey: .pane)
        case .split(let axis, let children, let fractions):
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
            try container.encode(fractions, forKey: .fractions)
        }
    }
}
