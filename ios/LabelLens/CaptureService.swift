import Foundation
import MWDATCamera
import MWDATCore

/// Wraps MWDATCamera to capture a single discrete photo from the paired
/// Meta Ray-Ban Display glasses camera - NOT continuous streaming.
///
/// DAT session-ownership note: a device can only have one DeviceSession
/// open at a time (the grounded API's `DeviceSessionError.sessionAlreadyExists`
/// implies this). Since DisplayService already keeps a DeviceSession open
/// for the life of the app flow (to drive the lens), this service does NOT
/// open a second one - it reuses DisplayService's shared session (passed in
/// by the caller) and only opens/closes the short-lived camera Stream on
/// top of it. The glasses' physical capture button is disabled only while
/// that Stream is open, so the Stream (not the session) is torn down
/// immediately after each capture.
@MainActor
final class CaptureService {

  enum CaptureError: Error {
    case sessionUnavailable
    case streamUnavailable
    case captureTriggerFailed
    case underlying(Error)
  }

  /// Opens a short-lived camera Stream on the given (already-open) shared
  /// DeviceSession, triggers a single still-photo capture, waits for the
  /// JPEG bytes to arrive on `photoDataPublisher`, then stops just the
  /// stream. The caller (AppFlowController) is expected to pass in
  /// DisplayService's shared session via `DisplayService.sharedDeviceSession()`.
  func captureSinglePhoto(session: DeviceSession) async throws -> Data {
    if session.state != .started {
      do {
        try session.start()
      } catch {
        throw CaptureError.underlying(error)
      }
      if session.state != .started {
        for await state in session.stateStream() {
          if state == .started { break }
          if state == .stopped {
            throw CaptureError.sessionUnavailable
          }
        }
      }
    }

    // addStream returns nil if the session isn't .started yet, per the
    // grounded API - we've already waited for .started above.
    let config = StreamConfiguration(
      videoCodec: .raw,
      resolution: .low,
      // Lowest supported frame rate: we only need a single still frame, not
      // a live feed, and this keeps the session as lightweight as possible.
      frameRate: 2
    )

    guard let stream = try session.addStream(config: config) else {
      throw CaptureError.streamUnavailable
    }
    stream.start()
    defer {
      stream.stop()
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
      var photoToken: AnyListenerToken?
      var errorToken: AnyListenerToken?
      var didResume = false

      let finish: (Result<Data, Error>) -> Void = { result in
        guard !didResume else { return }
        didResume = true
        photoToken = nil
        errorToken = nil
        continuation.resume(with: result)
      }

      photoToken = stream.photoDataPublisher.listen { data in
        finish(.success(data.data))
      }
      errorToken = stream.errorPublisher.listen { error in
        finish(.failure(CaptureError.underlying(error)))
      }

      let triggered = stream.capturePhoto(format: .jpeg)
      if !triggered {
        finish(.failure(CaptureError.captureTriggerFailed))
      }

      // TODO: verify against the real MWDAT API on a Mac whether a capture
      // timeout is needed here (e.g. the glasses never call back). No
      // timeout API was observed in the grounded sample code, so none is
      // added yet - add one if a real device shows it's needed.
    }
  }
}
