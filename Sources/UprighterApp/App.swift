import SwiftUI
import AppKit

/// Handles photos opened from Finder ("Open With", or dropping onto the icon)
/// and from `open -a Uprighter photo.jpg`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Library.shared.add(expand(urls)) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                out.append(contentsOf: (try? FileManager.default.contentsOfDirectory(
                    at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            } else {
                out.append(u)
            }
        }
        return out
    }
}

@main
struct UprighterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var library = Library.shared

    var body: some Scene {
        WindowGroup("Uprighter") {
            ContentView().environmentObject(library)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
