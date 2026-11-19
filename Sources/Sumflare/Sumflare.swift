import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Counts daily active users and custom events for an app in a Sumflare installation.
///
/// Call ``configure(appKey:host:userID:)`` once at launch. Sumflare then sends one signal when the
/// app starts and when it becomes active, at most once per UTC day. Each install gets a random ID
/// that stays on the device, unless the app passes its own user ID; nothing else about the user is
/// sent. Call ``track(_:value:)`` to count your own events, like a purchase or an export.
@MainActor
public enum Sumflare {
    private static var appKey: String?
    private static var endpoint: URL?
    private static var eventsEndpoint: URL?
    private static var customUserID: String?
    private static var observer: NSObjectProtocol?
    private static var isSending = false
    private static var pendingEvents: [[String: String]] = []
    private static var flushTask: Task<Void, Never>?

    /// The server takes at most this many events per request.
    private static let maxBatchSize = 50
    /// Events kept while offline. Older ones are dropped first beyond this.
    private static let maxPendingEvents = 500

    private static let userIDKey = "sumflare.userID"
    private static let lastSentDayKey = "sumflare.lastSentDay"

    /// Starts counting this app.
    /// - Parameters:
    ///   - appKey: The key shown for the app in the Sumflare dashboard.
    ///   - host: Your Sumflare URL, for example `https://stats.example.com`.
    ///   - userID: Your own ID for the signed-in user, if the app has one. The same person on several
    ///     devices then counts once. Leave it `nil` to use a random ID for this install. See
    ///     ``setUserID(_:)``.
    public static func configure(appKey: String, host: String, userID: String? = nil) {
        guard let base = URL(string: host) else {
            assertionFailure("Sumflare: invalid host \(host)")
            return
        }
        self.appKey = appKey
        customUserID = userID
        endpoint = base.appendingPathComponent("api/signal")
        eventsEndpoint = base.appendingPathComponent("api/events")
        observeActivation()
        signal()
        scheduleFlush()
    }

    /// Uses your own ID for the user, for example after they sign in, or `nil` to go back to the
    /// random install ID after they sign out. It is kept in memory only, so set it on every launch.
    ///
    /// Send an opaque ID such as a UUID or a hash of your account ID, not an email address. Today's
    /// signal is sent once, so a new ID is first counted on the next UTC day.
    public static func setUserID(_ userID: String?) {
        customUserID = userID
    }

    /// Sends today's signal if it hasn't been sent yet. Called for you on launch and activation.
    public static func signal() {
        guard let appKey, let endpoint, !isSending else {
            return
        }
        let today = utcDay()
        guard UserDefaults.standard.string(forKey: lastSentDayKey) != today else {
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "appKey": appKey,
            "userId": userID(),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "osVersion": osVersion(),
            "platform": platform,
        ])

        isSending = true
        Task {
            let isSent = await send(request)
            isSending = false
            // Only remember the day after the server accepted it, so a failed send retries later.
            if isSent {
                UserDefaults.standard.set(today, forKey: lastSentDayKey)
            }
        }
    }

    /// Counts an event, like a purchase or a tap on a button. You choose the names.
    ///
    /// Events are sent together a couple of seconds after the first one, and when the app goes to
    /// the background. They are kept in memory only, so events not sent before the app quits are
    /// lost. Don't put personal data such as email addresses in names or values.
    /// - Parameters:
    ///   - name: The event, up to 64 characters. For example `purchase` or `export`.
    ///   - value: An optional label to tell events of the same name apart, up to 100 characters.
    ///     For example `pro-yearly` or `pdf`.
    public static func track(_ name: String, value: String? = nil) {
        var event = ["name": name]
        if let value {
            event["value"] = value
        }
        pendingEvents.append(event)
        if pendingEvents.count > maxPendingEvents {
            pendingEvents.removeFirst(pendingEvents.count - maxPendingEvents)
        }
        if pendingEvents.count >= maxBatchSize {
            flush()
        } else {
            scheduleFlush()
        }
    }

    /// Sends waiting events now. Called for you shortly after ``track(_:value:)`` and when the app
    /// goes to the background.
    public static func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard let appKey, let eventsEndpoint, !pendingEvents.isEmpty else {
            return
        }
        let batch = Array(pendingEvents.prefix(maxBatchSize))
        pendingEvents.removeFirst(batch.count)

        var request = URLRequest(url: eventsEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["appKey": appKey, "events": batch])

        Task {
            // Only a network failure is retried. A response, even an error, means the server read
            // the batch, and sending it again would fail the same way.
            if await status(of: request) == nil {
                pendingEvents.insert(contentsOf: batch, at: 0)
                if pendingEvents.count > maxPendingEvents {
                    pendingEvents.removeFirst(pendingEvents.count - maxPendingEvents)
                }
                return
            }
            if !pendingEvents.isEmpty {
                flush()
            }
        }
    }

    private static func scheduleFlush() {
        guard flushTask == nil, !pendingEvents.isEmpty, eventsEndpoint != nil else {
            return
        }
        flushTask = Task {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            flushTask = nil
            flush()
        }
    }

    private nonisolated static func send(_ request: URLRequest) async -> Bool {
        await status(of: request) == 202
    }

    private nonisolated static func status(of request: URLRequest) async -> Int? {
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }
        return (response as? HTTPURLResponse)?.statusCode
    }

    private static func observeActivation() {
        guard observer == nil else {
            return
        }
        if let name = activationNotification {
            observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    signal()
                }
            }
        }
        if let name = backgroundNotification {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    flush()
                }
            }
        }
    }

    private static var backgroundNotification: Notification.Name? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        UIApplication.didEnterBackgroundNotification
        #elseif os(macOS)
        NSApplication.willResignActiveNotification
        #else
        // watchOS sends on the timer only.
        nil
        #endif
    }

    private static var activationNotification: Notification.Name? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        // watchOS only signals at launch.
        nil
        #endif
    }

    private static func userID() -> String {
        if let customUserID, !customUserID.trimmingCharacters(in: .whitespaces).isEmpty {
            return customUserID
        }
        if let existing = UserDefaults.standard.string(forKey: userIDKey) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: userIDKey)
        return created
    }

    private static func utcDay() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    private static var platform: String {
        #if targetEnvironment(macCatalyst)
        "macOS"
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(watchOS)
        "watchOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "Other"
        #endif
    }
}
