import Foundation

/// The mouse button the user holds to start Ball Scrolling.
/// Raw values are Core Graphics mouse button numbers.
public enum TriggerButton: Int, Codable, CaseIterable, Sendable, Identifiable {
    case right = 1
    case middle = 2
    case back = 3
    case forward = 4

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .right: return "Right button"
        case .middle: return "Middle button"
        case .back: return "Back button (4)"
        case .forward: return "Forward button (5)"
        }
    }
}

/// Everything that shapes how ball movement becomes scrolling.
public struct ScrollSettings: Codable, Equatable, Sendable {
    /// Pixels scrolled per ball count at slow speeds.
    public var speed: Double = 2.0
    /// Extra gain for fast rolls. 0 keeps the mapping linear.
    public var acceleration: Double = 0.5
    /// Ball counts ignored after the press before scrolling starts. 0 means any movement scrolls.
    public var deadZone: Double = 3
    /// Time constant, in seconds, used to spread ball input over display frames. 0 disables it.
    public var smoothing: Double = 0.03
    /// Restrict each gesture to the axis the ball first moved along.
    public var axisLock: Bool = true
    /// By default content follows the ball. These flip one axis.
    public var reverseVertical: Bool = false
    public var reverseHorizontal: Bool = false
    /// Glide after releasing the Trigger Button while the ball is still moving.
    public var momentum: Bool = true
    /// Time constant of the Momentum decay, in seconds. Larger glides further.
    public var momentumGlide: Double = 0.4

    public init() {}

    // Decode field by field so settings saved by an older version keep loading
    // when new fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScrollSettings()
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? d.acceleration
        deadZone = try c.decodeIfPresent(Double.self, forKey: .deadZone) ?? d.deadZone
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        axisLock = try c.decodeIfPresent(Bool.self, forKey: .axisLock) ?? d.axisLock
        reverseVertical = try c.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? d.reverseVertical
        reverseHorizontal = try c.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? d.reverseHorizontal
        momentum = try c.decodeIfPresent(Bool.self, forKey: .momentum) ?? d.momentum
        momentumGlide = try c.decodeIfPresent(Double.self, forKey: .momentumGlide) ?? d.momentumGlide
    }
}
