import Foundation
import MWDATCore
import MWDATDisplay

// NOTE: keep this file SwiftUI-free. MWDATDisplay's `Text`, `Button`, and
// `Image` types collide with SwiftUI's if both are imported in the same
// file (per Meta's display-access skill doc) - if SwiftUI is ever needed
// here, qualify as MWDATDisplay.Text / MWDATDisplay.Button / MWDATDisplay.Image.

/// Wraps MWDATDisplay: attaches to the glasses' Display capability and
/// renders composed UI (FlexBox/Text/Button/Image) to the 600x600 lens.
/// Display cannot show a live camera feed - only composed UI - so all
/// screens here are static layouts, not previews.
@MainActor
final class DisplayService {

  enum DisplayServiceError: Error {
    case sessionUnavailable
    case displayUnavailable
    case underlying(Error)
  }

  private let wearables: WearablesInterface
  private var deviceSession: DeviceSession?
  private var display: Display?
  // Cached readiness flag, updated only from `capability.statePublisher`
  // (see waitUntilStarted/subscribeToDisplayState below). Display has no
  // confirmed synchronous `.state` getter in the grounded API - only
  // DeviceSession does - so this is the only source of truth for whether
  // the Display capability is started.
  private var displayState: DisplayState?
  private var displayStateToken: AnyListenerToken?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
  }

  /// Attaches to the Display capability if not already attached/started.
  /// Unlike CaptureService's short-lived per-capture Streams, the
  /// DeviceSession itself is kept open for the life of the app flow:
  /// re-attaching on every screen change would be slow, and (unlike the
  /// camera) an open Display session doesn't disable any physical glasses
  /// control. CaptureService reuses this same session (via
  /// `sharedDeviceSession()`) rather than opening a second one, since the
  /// grounded API only supports one DeviceSession per device at a time
  /// (`DeviceSessionError.sessionAlreadyExists`).
  func attachIfNeeded() async throws {
    if let display, displayState == .started {
      return
    }

    let session = try await ensureSession()

    let capability: Display
    do {
      capability = try session.addDisplay()
    } catch {
      throw DisplayServiceError.underlying(error)
    }
    subscribeToDisplayState(capability)
    capability.start()
    try await waitUntilStarted(capability)

    display = capability
  }

  /// Returns the shared DeviceSession, opening and starting it first if
  /// needed. CaptureService calls this instead of opening its own session,
  /// so the glasses only ever have one DeviceSession open at a time.
  func sharedDeviceSession() async throws -> DeviceSession {
    try await ensureSession()
  }

  @discardableResult
  private func ensureSession() async throws -> DeviceSession {
    let session: DeviceSession
    if let existing = deviceSession {
      session = existing
    } else {
      let deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
      do {
        session = try wearables.createSession(deviceSelector: deviceSelector)
      } catch {
        throw DisplayServiceError.underlying(error)
      }
      deviceSession = session
    }

    if session.state != .started {
      do {
        try session.start()
      } catch {
        throw DisplayServiceError.underlying(error)
      }
      if session.state != .started {
        for await state in session.stateStream() {
          if state == .started { break }
          if state == .stopped { throw DisplayServiceError.sessionUnavailable }
        }
      }
    }

    return session
  }

  /// Sends exactly one root DisplayableView, replacing whatever was on the
  /// lens before (per the real API: each `send(_:)` call replaces the
  /// previous content and its tap handlers).
  func send(_ view: some DisplayableView) async throws {
    try await attachIfNeeded()
    guard let display else { throw DisplayServiceError.displayUnavailable }
    do {
      try await display.send(view)
    } catch {
      throw DisplayServiceError.underlying(error)
    }
  }

  func detach() {
    display?.stop()
    deviceSession?.stop()
    display = nil
    deviceSession = nil
    displayStateToken = nil
    displayState = nil
  }

  /// Persistent subscription that keeps `displayState` in sync for the
  /// life of this Display capability, so `attachIfNeeded()` can cheaply
  /// check readiness without ever reading a synchronous `.state` property
  /// off `Display` (not confirmed to exist in the grounded API).
  private func subscribeToDisplayState(_ capability: Display) {
    displayStateToken = capability.statePublisher.listen { [weak self] state in
      self?.displayState = state
    }
  }

  /// Mirrors the grounded DisplayViewModel pattern of bridging
  /// `statePublisher.listen` into an awaitable sequence while waiting for
  /// `DisplayState.started`.
  private func waitUntilStarted(_ capability: Display) async throws {
    if displayState == .started { return }

    var token: AnyListenerToken?
    let stream = AsyncStream<DisplayState> { continuation in
      token = capability.statePublisher.listen { state in
        continuation.yield(state)
        if state == .started || state == .stopped {
          continuation.finish()
        }
      }
    }

    for await state in stream {
      if state == .started {
        _ = token
        return
      }
      if state == .stopped {
        _ = token
        throw DisplayServiceError.displayUnavailable
      }
    }
    _ = token
    throw DisplayServiceError.displayUnavailable
  }
}

/// The three LabelLens glasses screens. Each function returns a root
/// FlexBox - the exact FlexBox/Text/Button/Image DSL from Meta's
/// CarMaintenanceDisplay.swift sample - and takes closures for navigation
/// so this file never hardcodes app flow logic.
enum LabelLensScreens {

  /// (a) Idle / instructions screen with a single Scan button.
  static func idle(onScan: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .center) {
      FlexBox(direction: .column) {
        Text("LabelLens", style: .heading)
        Text("Point your glasses at a food label, then tap Scan.", style: .body, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
        // TODO: verify a real IconName exists for "camera"/"scan" once on a
        // Mac with the real MWDATDisplay docs - only iconName values seen in
        // the grounded sample were triangleLeftVerticalLine,
        // triangleRightVerticalLine, checkmark, videoCamera, gear - so no
        // iconName is set here rather than inventing one.
        Button(label: "Scan", style: .primary, onClick: onScan)
      }
    }
  }

  /// (b) "Reading label" processing screen. No camera preview - Display
  /// cannot show a live feed, only composed UI - so this is a status text
  /// screen shown while capture + backend verdict are in flight.
  static func processing(statusText: String = "Reading label...") -> FlexBox {
    FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .center) {
      FlexBox(direction: .column) {
        Text(statusText, style: .heading)
        Text("Hold steady for a moment.", style: .meta, color: .secondary)
      }
      .padding(24)
      .background(.card)
    }
  }

  /// (c) Verdict card: product/ingredient name, status (conveyed via wording
  /// - see statusColor's TODO below for why it isn't color-coded yet),
  /// one-line reasoning, and a Prev/Next/Details button row - mirroring
  /// CarMaintenanceDisplay.swift's button-row pattern - so the glasses
  /// OS-level swipe-to-navigate / pinch-to-select gestures can drive
  /// navigation for free.
  static func verdictCard(
    verdict: Verdict,
    onPrev: @escaping @Sendable () -> Void,
    onNext: @escaping @Sendable () -> Void,
    onDetails: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column) {
        Text(verdict.productName, style: .heading)
        Text(statusLabel(for: verdict.status), style: .body, color: statusColor(for: verdict.status))
        Text(verdict.reason, style: .meta, color: .secondary)
        if let personalFlag = verdict.personalFlag {
          Text(personalFlag, style: .meta, color: .secondary)
        }
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
        Button(label: "Prev", style: .secondary, iconName: .triangleLeftVerticalLine, onClick: onPrev)
        Button(label: "Next", style: .primary, iconName: .triangleRightVerticalLine, onClick: onNext)
        Button(label: "Details", style: .secondary, onClick: onDetails)
      }
    }
  }

  private static func statusLabel(for status: String) -> String {
    switch status.lowercased() {
    case "good": return "Good to go"
    case "caution": return "Use caution"
    case "avoid": return "Avoid"
    default: return status.capitalized
    }
  }

  /// TextColor is confirmed as the real way to color-code Text, but the
  /// grounded sample code only ever shows two cases: `.primary`/`.secondary`.
  /// There's no confirmed evidence of green/amber/red status-color cases
  /// (`.success`/`.warning`/`.danger` were a guess and are NOT used here,
  /// since guessing a nonexistent enum case would fail to compile). Status
  /// is instead conveyed entirely through `statusLabel`'s wording ("Good to
  /// go" / "Use caution" / "Avoid"). TODO: once on a Mac with the real
  /// MWDATDisplay docs, check whether TextColor actually has status-color
  /// cases (or some other color-coding API) and wire real colors in here.
  private static func statusColor(for status: String) -> TextColor {
    .primary
  }
}
