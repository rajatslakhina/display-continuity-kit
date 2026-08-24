// DisplayClass.swift
//
// The architectural boundary this package exists to defend:
//
//   Feature modules never branch on the device, the screen, or a fold state.
//   They read a `CapacityPlan`. `DisplayClass` is the only thing that knows a
//   foldable exists, and it is derived from geometry — not from a device check.
//
// That indirection is what keeps a hardware generation from leaking into
// forty feature modules.

/// A sanitised viewport measurement.
///
/// The initialiser is total: non-finite and negative inputs collapse to `0`
/// rather than propagating into the capacity derivation.
public struct Viewport: Sendable, Hashable, Codable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = Saturating.dimension(width)
        self.height = Saturating.dimension(height)
    }

    /// Area in square points. Always finite and non-negative.
    ///
    /// The product of two sanitised dimensions can still overflow to
    /// `+.infinity` for absurd inputs, so it is re-sanitised on the way out.
    public var area: Double { Saturating.dimension(width * height) }

    /// The zero viewport — what a scene reports before its first layout pass.
    public static let zero = Viewport(width: 0, height: 0)

    // Reference geometry for the two iPhone Fold surfaces, in points.
    // These are *sample* values used by the demo and the default resolver
    // threshold; nothing in the package hardcodes a device identifier.

    /// Approximate cover-display geometry (the 5.5" outer screen).
    public static let coverDisplay = Viewport(width: 372, height: 812)

    /// Approximate inner-display geometry (the 7.8" near-square screen).
    public static let innerDisplay = Viewport(width: 716, height: 820)
}

/// The runtime capacity class of the surface an interface is currently on.
///
/// Deliberately *not* named for the hardware. A tablet, a resized macOS window
/// and an unfolded phone are the same problem, and code that says `.expanded`
/// keeps working when the next form factor ships.
public enum DisplayClass: String, Sendable, Hashable, Codable, CaseIterable {
    /// One pane visible. Detail is pushed, not shown alongside.
    case compact
    /// Two panes visible. A detail pane exists whether or not anyone asked for it.
    case expanded

    /// Ordering used to decide whether a transition is a *growth* or a *shrink*.
    /// Growth and shrink are handled asymmetrically — see `TransitionCoalescer`.
    public var capacityRank: Int {
        switch self {
        case .compact: return 0
        case .expanded: return 1
        }
    }

    /// Whether this class renders a detail pane alongside the primary list.
    public var showsDetailPane: Bool { self == .expanded }
}

/// Maps geometry to a `DisplayClass`.
///
/// A protocol rather than a free function so a test — or a demo — can drive an
/// arbitrary sequence of display classes without fabricating plausible
/// geometry, and so a host app can override the threshold for its own layout.
public protocol DisplayClassResolving: Sendable {
    func displayClass(for viewport: Viewport) -> DisplayClass
}

/// Resolves on the shorter edge, which is the dimension that actually gates a
/// two-pane layout.
///
/// Rejected alternative: resolving on `area`. Area classifies a short-and-wide
/// landscape phone as `.expanded` even though its 390pt height cannot host a
/// usable detail pane. The minimum edge is the honest predictor.
public struct MinimumEdgeDisplayClassResolver: DisplayClassResolving {
    /// Shorter-edge threshold, in points, at or above which a second pane fits.
    public let expandedThreshold: Double

    /// - Parameter expandedThreshold: Defaults to `600`, which sits between the
    ///   Fold's 372pt cover width and its 716pt inner width with margin on both
    ///   sides. Non-finite or negative values fall back to the default rather
    ///   than producing a resolver that classifies everything as `.expanded`.
    public init(expandedThreshold: Double = 600) {
        self.expandedThreshold = expandedThreshold.isFinite && expandedThreshold > 0
            ? expandedThreshold
            : 600
    }

    public func displayClass(for viewport: Viewport) -> DisplayClass {
        let minimumEdge = min(viewport.width, viewport.height)
        return minimumEdge >= expandedThreshold ? .expanded : .compact
    }
}

/// Identifies a navigation surface — a tab, a window, a scene.
///
/// State is scoped to *this*, not to a screen. That is the whole point: a
/// screen disappears when the device folds; the surface does not.
public struct SurfaceID: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Identifies a content item. Opaque to this package.
public struct ItemID: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}
