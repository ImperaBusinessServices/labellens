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
    case timedOut
    case underlying(Error)
  }

  /// How long to wait for the glasses to return a photo before giving up.
  /// Prevents a permanent hang on the button-less processing screen if the
  /// device accepts the trigger but never fires a photo/error callback.
  private static let captureTimeoutNanos: UInt64 = 10_000_000_000  // 10s

  /// Opens a short-lived camera Stream on the given (already-open) shared
  /// DeviceSession, triggers a single still-photo capture, waits for the
  /// JPEG bytes to arrive on `photoDataPublisher`, then stops just the
  /// stream. The caller (AppFlowController) is expected to pass in
  /// DisplayService's shared session via `DisplayService.sharedDeviceSession()`.
  func captureSinglePhoto(session: DeviceSession) async throws -> Data {
    if session.state != .started {
      // Capture the state stream BEFORE start(): the .started transition can
      // land on another thread before we begin iterating, and the stream
      // doesn't buffer past events, so subscribing after start() could hang
      // forever. This mirrors Meta's own DeviceSessionManager sample.
      let stateStream = session.stateStream()
      do {
        try session.start()
      } catch {
        throw CaptureError.underlying(error)
      }
      if session.state != .started {
        for await state in stateStream {
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
      var timeoutTask: Task<Void, Never>?
      var didResume = false

      // The photo/error callbacks are @Sendable and fire on background
      // threads, while the timeout and the trigger-failure path run on the
      // main actor - so resume-once must be guarded by a lock, or two of them
      // could both pass the check and resume the continuation twice (a crash).
      let resumeLock = NSLock()

      let finish: (Result<Data, Error>) -> Void = { result in
        resumeLock.lock()
        if didResume {
          resumeLock.unlock()
          return
        }
        didResume = true
        resumeLock.unlock()

        timeoutTask?.cancel()
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

      // Fail (rather than hang forever) if the glasses accept the trigger but
      // never call back. This lets AppFlowController's catch path run, which
      // returns to the idle screen and stops the stream via `defer`.
      timeoutTask = Task {
        try? await Task.sleep(nanoseconds: CaptureService.captureTimeoutNanos)
        finish(.failure(CaptureError.timedOut))
      }

      let triggered = stream.capturePhoto(format: .jpeg)
      if !triggered {
        finish(.failure(CaptureError.captureTriggerFailed))
      }
    }
  }
}
