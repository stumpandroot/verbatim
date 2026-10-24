import Foundation
import os

/// Signpost intervals for Instruments (the Points of Interest track): screen changes, the launch library load,
/// still decoding, and app-icon lookups. Signposts cost almost nothing unless Instruments is recording, so they
/// stay on in Release builds. Profile a Release build on hardware with the SwiftUI and Time Profiler templates.
enum Perf {
    static let signposter = OSSignposter(subsystem: "co.stumpandroot.verbatim", category: .pointsOfInterest)
}
