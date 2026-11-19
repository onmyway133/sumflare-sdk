# Sumflare Swift SDK

Daily active users and custom events for iOS, iPadOS, macOS, tvOS, watchOS and visionOS apps,
sent to your own [Sumflare](https://github.com/onmyway133/sumflare) install.

## Install

In Xcode, choose **File → Add Package Dependencies** and enter:

```
https://github.com/onmyway133/sumflare-sdk
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/onmyway133/sumflare-sdk", branch: "main")
```

## Daily active users

In the Sumflare dashboard, add your app to get its app key. Then call this once at launch:

```swift
import Sumflare

@main
struct MyApp: App {
    init() {
        Sumflare.configure(appKey: "YOUR_APP_KEY", host: "https://stats.example.com")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

The package creates a random ID for the install, stores it on the device, and sends one signal
per UTC day when the app launches or becomes active.

If your app has its own user IDs, pass one so a person on several devices counts once. Use an
opaque ID (a UUID or a hash of your account ID), not an email address:

```swift
Sumflare.configure(appKey: "YOUR_APP_KEY", host: "https://stats.example.com", userID: account?.id)

// Or later, after sign in or sign out:
Sumflare.setUserID(account.id)
Sumflare.setUserID(nil)
```

## Events

Count your own events. You choose the names, and an optional value tells events of the same name
apart:

```swift
Sumflare.track("onboarding_done")
Sumflare.track("purchase", value: "pro-yearly")
Sumflare.track("export", value: "pdf")
```

Events are sent together a couple of seconds after the first one, and when the app goes to the
background. They are kept in memory, so events not sent before the app quits are lost. Names can
be up to 64 characters and values up to 100. Don't put personal data in them. Only a count per
day, name and value is stored.

## License

MIT. See [LICENSE](LICENSE).
