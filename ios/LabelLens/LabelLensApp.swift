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
    do {
      try Wearables.configure()
      configureFailed = false
    } catch {
      configureFailed = true
      #if DEBUG
      NSLog("[LabelLens] Failed to configure Wearables SDK: \(error)")
      #endif
    }
    let wearables = Wearables.shared
    self.wearables = wearables
    self._appFlowController = State(wrappedValue: AppFlowController(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      // The phone-side window is just the companion/setup screen for v1
      // (fill in HealthProfile once). The actual "app" experience for a
      // scan renders on the glasses lens via DisplayService/AppFlowController.
      // Profile editing needs no SDK, so it stays available even when
      // configure() failed - only the glasses flow is skipped, with a
      // visible banner instead of a silent failure or a dead-end screen.
      VStack(spacing: 0) {
        if configureFailed {
          Text("Glasses connection couldn't start - scanning is unavailable. Quit and reopen the app to retry.")
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundColor(.white)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.85))
        }
        ProfileSetupView()
          .task {
            if !configureFailed {
              await appFlowController.start()
            }
          }
      }

      // Mirrors the grounded RegistrationView pattern: an invisible view
      // whose only job is to catch the MWDAT registration deep-link
      // callback and hand it to the SDK. Kept mounted unconditionally so a
      // pairing callback is never dropped.
      RegistrationView(wearables: wearables)
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
