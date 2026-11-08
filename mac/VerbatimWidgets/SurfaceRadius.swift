import CoreGraphics

/// Radii for the small surfaces (SF-24; DESIGN.md §5.3, "use the tokens, never a number"): the Home Screen and desktop
/// widgets, the Live Activities, and the keyboard. `Radius` in Tokens.swift holds the apps' radii (and the watch's);
/// these are the sizes only these surfaces use, named once. Compiled into the iPhone and Mac widget extensions and the
/// keyboard (project.yml). `mac/tools/brand-check.sh` fails on a `cornerRadius:` number in those targets and the
/// watch's.
enum SurfaceRadius {
    /// The medium Record and dictate widget's two tiles (the iPhone card radius, `RefinedRules.radius(.card)`).
    static let widgetTile: CGFloat = 14
    /// This week's bars.
    static let weekBar: CGFloat = 1.5
    /// The Live Activity's 10 pt stop square.
    static let stopSquare: CGFloat = 2
    /// The keyboard's letter and function keys, as Apple's keyboard rounds them.
    static let key: CGFloat = 7
    /// The keyboard's cards (Home's panels, the menu card, notices).
    static let keyboardCard: CGFloat = 14
    /// The keyboard's 34 pt chips and pills: half their height, so they read as capsules.
    static let keyboardChip: CGFloat = 17
}
