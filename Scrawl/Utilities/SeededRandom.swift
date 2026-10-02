import Foundation

/// Small, fast, deterministic PRNG (mulberry32). Identical seeds always yield identical sequences
/// on every platform, which keeps sketch rendering stable across frames, saves and exports.
struct SeededRandom {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func nextUInt32() -> UInt32 {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return t ^ (t >> 14)
    }

    /// Uniform value in [0, 1).
    mutating func next() -> Double { Double(nextUInt32()) / 4_294_967_296.0 }

    /// Uniform value in [-1, 1).
    mutating func signed() -> Double { next() * 2 - 1 }

    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }

    static func randomSeed() -> UInt32 { UInt32.random(in: 1...UInt32.max) }
}
