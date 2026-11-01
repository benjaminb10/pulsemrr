// Share what the dashboard window shows (the project or projects picked, the period) as an image or a PDF, to send
// a snapshot of the moment to a partner: the same drawing as `--dashboard-snapshot`, dated, without the window around it.
import AppKit
import SwiftUI

/// The moment an export was drawn: the header shows it instead of "Updated just now".
private struct ExportedAtKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    var exportedAt: Date? {
        get { self[ExportedAtKey.self] }
        set { self[ExportedAtKey.self] = newValue }
    }
}

@MainActor
enum DashboardShare {
    enum Format { case png, pdf }

    /// "BeReach", "All projects", or the projects ticked.
    static func title(_ model: Model) -> String {
        if let id = model.dashboardScope, let a = model.active.first(where: { $0.id == id }) { return a.name }
        if model.dashboardAll { return String(localized: "All projects") }
        return model.dashboardAccounts.map(\.name).joined(separator: " + ")
    }

    private static func content(_ model: Model, now: Date) -> some View {
        DashboardContent(model: model)
            .padding(28).frame(width: 1180)
            .background(Palette.canvas)
            .environment(\.isSnapshot, true)
            .environment(\.exportedAt, now)
            .environment(\.locale, Money.locale)
            .environment(\.colorScheme, NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }

    /// Draws the page into a file in a temporary folder, named after the view and the day.
    static func render(_ model: Model, _ format: Format, now: Date = Date()) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PulseMRR share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "PulseMRR \(title(model).replacingOccurrences(of: "/", with: "-")) \(stamp.string(from: now))"
        let r = ImageRenderer(content: content(model, now: now))
        switch format {
        case .png:
            // Retina, unless the page is so tall the image would pass 16,000 pixels
            let height = r.nsImage?.size.height ?? 4000
            r.scale = min(2, 16000 / max(1, height))
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            let url = dir.appendingPathComponent(name + ".png")
            return (try? png.write(to: url)) == nil ? nil : url
        case .pdf:
            // One tall page, drawn as vectors: sharp at any zoom
            let url = dir.appendingPathComponent(name + ".pdf")
            var ok = false
            r.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: name] as CFDictionary) else { return }
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
                ctx.closePDF()
                ok = true
            }
            return ok ? url : nil
        }
    }

    /// The system share menu (Messages, Mail, AirDrop, WhatsApp…) under the toolbar's Share button.
    static func share(_ model: Model, _ format: Format) {
        // The dashboard window, even when another app has the focus
        let window = NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.contains("dashboard") == true || $0.title == "PulseMRR") } ?? NSApp.keyWindow
        guard let url = render(model, format), let view = window?.contentView else { return NSSound.beep() }
        let y = view.isFlipped ? 0 : view.bounds.maxY
        NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(x: view.bounds.maxX - 70, y: y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    static func copyImage(_ model: Model) {
        guard let url = render(model, .png), let img = NSImage(contentsOf: url) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    static func save(_ model: Model, _ format: Format) {
        guard let url = render(model, format) else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}
