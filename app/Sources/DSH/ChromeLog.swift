import AppKit
import Foundation

enum ChromeLog {
    static let path = URL(fileURLWithPath: "/tmp/dsh-studio.log")

    static func line(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(message)\n"
        NSLog("[dsh] %@", message)
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path.path) {
            if let handle = try? FileHandle(forWritingTo: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: path)
        }
    }
}

@MainActor
enum StudioChrome {
    static var windowTitle = "DSH Studio"

    static func apply(_ title: String, window: NSWindow? = nil) {
        if windowTitle == title, window == nil || window?.title == title { return }
        windowTitle = title
        ChromeLog.line("title chrome=\(title)")
        if let window {
            window.title = title
            return
        }
        for item in NSApp.windows where item.isVisible && item.canBecomeMain {
            item.title = title
        }
    }
}
