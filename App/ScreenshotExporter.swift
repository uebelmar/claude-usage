import AppKit
import SwiftUI
import WidgetKit

/// `ClaudeUsage --export-screenshots <ordner>` rendert die Widget-Größen mit den aktuellen Daten
/// (E-Mail-Adressen unscharf) als PNG – für README/Release, ohne Bildschirmaufnahme-Rechte.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--export-screenshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        Task { @MainActor in
            ScreenshotExporter.export(to: dir)
            exit(0)
        }
    }
}

@MainActor
enum ScreenshotExporter {
    static func export(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = UsageEntry(date: .now, snapshot: SnapshotStore.load() ?? .preview)
        let sizes: [(String, WidgetFamily, CGSize)] = [
            ("small", .systemSmall, CGSize(width: 170, height: 170)),
            ("medium", .systemMedium, CGSize(width: 364, height: 170)),
            ("large", .systemLarge, CGSize(width: 364, height: 382)),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, family, size) in sizes {
                let view = UsageWidgetView(entry: entry, family: family)
                    .padding(16)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .environment(\.colorScheme, scheme)
                    .environment(\.blurEmails, true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                renderer.isOpaque = false
                guard let cg = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                let file = dir.appendingPathComponent("widget-\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: file)
                print("written \(file.path)")
            }
        }
    }
}
