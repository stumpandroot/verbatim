import SwiftUI

enum VerbiePose: Equatable {
    case ready, listening, receiving, working, saved, paused, permission, interrupted, nothing

    /// Arm angles in degrees, from the prototype rig (verbie-rig.js).
    var armR: Double { switch self {
        case .ready: return 0; case .listening: return -150; case .receiving: return -95; case .working: return 85
        case .saved: return -165; case .paused: return 12; case .permission: return -110; case .interrupted: return -60; case .nothing: return -115 } }
    var armL: Double { switch self {
        case .ready: return 0; case .listening: return 8; case .receiving: return 95; case .working: return -75
        case .saved: return -15; case .paused: return -8; case .permission: return 5; case .interrupted: return 40; case .nothing: return 115 } }
    var barGrip: Double { switch self {
        case .receiving: return -50; case .working: return 95; case .interrupted: return -30; case .nothing: return -60; default: return 0 } }
    var handR: Double { switch self {
        case .listening: return -40; case .saved: return -50; case .permission: return 110; case .nothing: return 35; case .receiving: return 20; default: return 0 } }
    var lean: Double { switch self {
        case .listening: return -6; case .paused: return 7; case .permission: return 3; case .nothing: return -4; default: return 0 } }
}
