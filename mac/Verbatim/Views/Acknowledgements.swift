import SwiftUI

/// Open-source software in Verbatim and its licenses: Settings › About › Acknowledgements on the Mac, Settings ›
/// Support › Acknowledgements on the iPhone. The notice and license ship in the app's resources
/// (Verbatim/Resources/FFmpeg); the version and configure options come from the FFmpeg libraries the app loaded,
/// so they stay right if you replace those libraries with your own build.
enum Acknowledgements {
    static func resource(_ name: String) -> String {
        guard let u = Bundle.main.url(forResource: name, withExtension: "txt"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }
    static var ffmpegNotice: String { resource("FFmpeg-NOTICE") }
    static var ffmpegLicense: String { resource("FFmpeg-LICENSE") }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("FFmpeg")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(Acknowledgements.ffmpegNotice)
                    .font(.system(size: 13)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("Loaded in this copy of Verbatim")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 6)
                Text("FFmpeg \(FFmpegAudio.version), \(FFmpegAudio.license)")
                    .font(.system(size: 13)).foregroundStyle(Ink.ink)
                    .textSelection(.enabled)
                Text(FFmpegAudio.configuration)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("GNU Lesser General Public License, version 2.1")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 6)
                Text(Acknowledgements.ffmpegLicense)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Ink.paper)
    }
}
