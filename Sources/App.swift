// PulseMRR: a native notification for every Stripe sale, subscriber, cancellation or failed payment,
// across all your Stripe accounts, with today's takings and the MRR in the menu bar. No server.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    // Show the banner even though a menu bar app counts as the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    // Clicking a notification opens the payment, subscription or dispute in the Stripe dashboard.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        done()
    }
}

@main
struct PulseMRRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    init() {
        // `PulseMRR --add-account "Name" "emoji"` with the key on stdin: adds an account without the window.
        let args = CommandLine.arguments
        // `PulseMRR --demo-snapshot out.png [dark]`: the panel with made-up projects, for the README.
        if let i = args.firstIndex(of: "--demo-snapshot"), args.count > i + 1 {
            let out = URL(fileURLWithPath: args[i + 1])
            let dark = args.contains("dark")
            MainActor.assumeIsolated {
                Money.locale = Locale(identifier: "en_US")
                let m = Model.demo()
                let view = MenuPanel(model: m)
                    .environment(\.isSnapshot, true)
                    .environment(\.locale, Money.locale)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: out)
                    print("demo snapshot \(out.path)")
                }
            }
            exit(0)
        }
        // `PulseMRR --dashboard-snapshot out.png [dark] [demo] [project N]`: the dashboard window's content as an image,
        // with made-up projects (demo) or live data, for the README and for checks.
        if let i = args.firstIndex(of: "--dashboard-snapshot"), args.count > i + 1 {
            let out = URL(fileURLWithPath: args[i + 1])
            let dark = args.contains("dark"), demo = args.contains("demo")
            let project = args.firstIndex(of: "project").flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil }
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                if demo { Money.locale = Locale(identifier: "en_US") }
                let m = demo ? Model.demo() : Model()
                if !demo { await m.refreshStats(); await m.loadDashboard() }
                if let project, m.active.indices.contains(project) { m.dashboardScope = m.active[project].id }
                m.rebuildDashboard()
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let view = DashboardContent(model: m)
                    .padding(28).frame(width: 1180)
                    .background(Palette.canvas)
                    .environment(\.isSnapshot, true)
                    .environment(\.locale, Money.locale)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: out)
                    print("dashboard snapshot \(out.path)")
                }
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        // `PulseMRR --snapshot out.png`: draws the menu panel to an image, with live data (for docs and checks).
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
            let out = URL(fileURLWithPath: args[i + 1])
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let m = Model()
                await m.pollAll()
                await m.refreshStats()
                let r = ImageRenderer(content: MenuPanel(model: m).environment(\.isSnapshot, true).background(Color(nsColor: .windowBackgroundColor)))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: out)
                    print("snapshot \(out.path)")
                }
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        // `PulseMRR --notif-status`: what macOS allows for PulseMRR's notifications.
        if args.contains("--notif-status") {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in print(await Model().notificationStatus()); sem.signal() }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        // `PulseMRR --launch-status`: whether PulseMRR opens at login.
        if args.contains("--launch-status") {
            let st = SMAppService.mainApp.status
            print(st == .enabled ? "enabled" : st == .requiresApproval ? "requiresApproval" : st == .notRegistered ? "notRegistered" : "notFound")
            exit(0)
        }
        // `PulseMRR --recap`: prints today's recap with live data (to check it before 20 h).
        if args.contains("--recap") {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let m = Model()
                await m.refreshStats()
                let r = m.recapText()
                print(r.title); print(r.body)
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--add-account") {
            let name = args.count > i + 1 ? args[i + 1] : ""
            let emoji = args.count > i + 2 ? args[i + 2] : ""
            let key = readLine(strippingNewline: true) ?? ""
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                do {
                    let a = try await Model().addAccount(name: name, emoji: emoji, key: key, connected: "")
                    print("added \(a.name) \(a.stripeID) \(a.live ? "live" : "test")")
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
                .task { model.start() }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("PulseMRR", id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: 1240, height: 880)

        Window("PulseMRR Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar item: the icon, today's amount and today's new customers. `--dashboard` at launch opens the dashboard.
struct MenuBarLabel: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "dollarsign.circle.fill")
            if !model.menuBarTitle.isEmpty { Text(model.menuBarTitle).monospacedDigit() }
            // New customers today, trials included
            if model.prefs.showSignupsInMenuBar, !model.accounts.isEmpty, model.newCustomers(0) > 0 {
                Image(systemName: "person.fill")
                Text("\(model.newCustomers(0))").monospacedDigit()
            }
        }
        .task {
            model.start()
            if CommandLine.arguments.contains("--dashboard") { openWindow(id: "dashboard") }
        }
    }
}
