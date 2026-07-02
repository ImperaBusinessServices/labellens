import Foundation
import MWDATCore
import SwiftUI

/// SwiftUI app entry point. Mirrors Meta's official CameraAccessApp.swift /
/// DisplayAccessApp.swift init pattern exactly: `Wearables.configure()` is
/// called once in `init()`, then `Wearables.shared` is used everywhere else.
@main
struct LabelLensApp: App {
  private let wearables: WearablesInterface
  @State private var appFlowController: AppFlowController

  init() {
    do {
      try Wearables.configure()
    } catch {
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
