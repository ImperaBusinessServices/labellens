import Foundation
import MWDATCore
import SwiftUI

/// SwiftUI app entry point. Mirrors Meta's official CameraAccessApp.swift /
/// DisplayAccessApp.swift init pattern exactly: `Wearables.configure()` is
/// called once in `init()`, then `Wearables.shared` is used everywhere else.
@main
struct LabelLensApp: App {
  private let wearables: WearablesInterface
  private let configureFailed: Bool
  @State private var appFlowController: AppFlowController

  init() {
    var failed = false
    do {
      try Wearables.configure()
    } catch {
      failed = true
      #if DEBUG
      NSLog("[LabelLens] Failed to configure Wearables SDK: \(error)")
      #endif
    }
    self.configureFailed = failed
    let wearables = Wearables.shared
    self.wearables = wearables
    self._appFlowController = State(wrappedValue: AppFlowController(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      if configureFailed {
        // Don't silently proceed on an unconfigured SDK (every glasses call
        // would fail with no explanation). Tell the user instead.
        VStack(spacing: 12) {
          Text("Setup problem").font(.headline)
          Text("LabelLens couldn't start its glasses connection. Please restart the app.")
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
        }
        .padding()
      } else {
        // The phone-side window is just the companion/setup screen for v1
        // (fill in HealthProfile once). The actual "app" experience for a
        // scan renders on the glasses lens via DisplayService/AppFlowController.
        ProfileSetupView()
          .task {
            await appFlowController.start()
          }

        // Mirrors the grounded RegistrationView pattern: an invisible view
        // whose only job is to catch the MWDAT registration deep-link
        // callback and hand it to the SDK.
        RegistrationView(wearables: wearables)
      }
    }
  }
}

/// Exact deep-link callback pattern from Meta's sample RegistrationView.swift:
/// an EmptyView with `.onOpenURL`, filtering for the `metaWearablesAction`
/// query item before calling `Wearables.shared.handleUrl(url)`.
private struct RegistrationView: View {
  let wearables: WearablesInterface

  var body: some View {
    EmptyView()
      .onOpenURL { url in
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        Task {
          do {
            _ = try await wearables.handleUrl(url)
          } catch {
            #if DEBUG
            NSLog("[LabelLens] handleUrl failed: \(error)")
            #endif
          }
        }
      }
  }
}
