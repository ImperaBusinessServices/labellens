import Foundation
import MWDATCore
import MWDATDisplay

/// Ties everything together: idle screen "Scan" tap -> CaptureService grabs
/// a photo from the glasses camera -> show a processing screen ->
/// VerdictClient asks the backend for a verdict -> show the verdict screen
/// with Prev/Next/Details wired up.
@MainActor
final class AppFlowController {

  private let wearables: WearablesInterface
  private let captureService: CaptureService
  private let displayService: DisplayService
  private let verdictClient = VerdictClient()

  private var currentVerdict: Verdict?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.captureService = CaptureService()
    self.displayService = DisplayService(wearables: wearables)
  }

  /// Call once at app launch (after the phone has an active glasses
  /// pairing/registration) to render the idle screen on the lens.
  func start() async {
    await showIdle()
  }

  private func showIdle() async {
    currentVerdict = nil
    let screen = LabelLensScreens.idle { [weak self] in
      Task { await self?.handleScanTapped() }
    }
    await sendSafely(screen)
  }

  private func handleScanTapped() async {
    await sendSafely(LabelLensScreens.processing())

    do {
      // Reuse DisplayService's already-open DeviceSession rather than
      // opening a second one - the glasses only support one at a time.
      let session = try await displayService.sharedDeviceSession()
      let photoData = try await captureService.captureSinglePhoto(session: session)
      let profile = HealthProfileStore.load()
      let verdict = try await verdictClient.getVerdict(photoJPEG: photoData, healthProfile: profile)
      currentVerdict = verdict
      await showVerdict(verdict)
    } catch {
      // v1: fall back to the idle screen on any capture/network failure.
      // TODO: surface a dedicated error screen once we've settled on copy
      // for it (e.g. "Couldn't read that label - try again").
      #if DEBUG
      NSLog("[LabelLens] Scan flow failed: \(error)")
      #endif
      await showIdle()
    }
  }

  private func showVerdict(_ verdict: Verdict) async {
    // v1 supports a single ingredient/product per scan, so Prev/Next are
    // effectively no-ops here (Prev does nothing; Next re-triggers another
    // scan rather than paging through a list).
    // TODO (v1.1): once the backend can return multiple flagged
    // ingredients per scan, wire Prev/Next to page through that list
    // instead.
    let screen = LabelLensScreens.verdictCard(
      verdict: verdict,
      onPrev: { /* no-op in v1 - see TODO above */ },
      onNext: { [weak self] in
        Task { await self?.handleScanTapped() }
      },
      onDetails: { [weak self] in
        Task { await self?.showDetails() }
      }
    )
    await sendSafely(screen)
  }

  private func showDetails() async {
    // TODO: build a dedicated details screen (full reasoning, ingredient
    // breakdown, etc.) - v1 just re-shows the current verdict card, since
    // its reasoning line is already visible there.
    guard let currentVerdict else { return }
    await showVerdict(currentVerdict)
  }

  private func sendSafely(_ screen: FlexBox) async {
    do {
      try await displayService.send(screen)
    } catch {
      #if DEBUG
      NSLog("[LabelLens] Display send failed: \(error)")
      #endif
    }
  }
}
