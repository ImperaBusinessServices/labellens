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
      let completion = CaptureCompletion(continuation: continuation)

      let photoToken = stream.photoDataPublisher.listen { data in
        completion.finish(.success(data.data))
      }
      let errorToken = stream.errorPublisher.listen { error in
        completion.finish(.failure(CaptureError.underlying(error)))
      }
      completion.store(photoToken: photoToken, errorToken: errorToken)

      // Fail (rather than hang forever) if the glasses accept the trigger but
      // never call back. This lets AppFlowController's catch path run, which
      // returns to the idle screen and stops the stream via `defer`.
      completion.storeTimeout(Task {
        try? await Task.sleep(nanoseconds: CaptureService.captureTimeoutNanos)
        guard !Task.isCancelled else { return }
        completion.finish(.failure(CaptureError.timedOut))
      })

      let triggered = stream.capturePhoto(format: .jpeg)
      if !triggered {
        completion.finish(.failure(CaptureError.captureTriggerFailed))
      }
    }
  }
}

/// All mutable capture-completion state lives behind one lock, so the photo
/// callback, error callback, timeout, and trigger-failure paths - which run
/// on different threads - can never race each other or resume the
/// continuation twice. Using a class instead of captured local vars also
/// keeps this legal under Swift 6 strict concurrency (no mutation of
/// captured locals from @Sendable closures).
private final class CaptureCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false
  private var photoToken: AnyListenerToken?
  private var errorToken: AnyListenerToken?
  private var timeoutTask: Task<Void, Never>?
  private let continuation: CheckedContinuation<Data, Error>

  init(continuation: CheckedContinuation<Data, Error>) {
    self.continuation = continuation
  }

  /// Retain the listener tokens for the life of the wait (dropped in finish).
  func store(photoToken: AnyListenerToken?, errorToken: AnyListenerToken?) {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else { return }
    self.photoToken = photoToken
    self.errorToken = errorToken
  }

  /// Retain the timeout task so finish() can cancel it; if the capture
  /// already finished before this is called, cancel the task immediately.
  func storeTimeout(_ task: Task<Void, Never>) {
    lock.lock()
    let alreadyDone = didResume
    if !alreadyDone { timeoutTask = task }
    lock.unlock()
    if alreadyDone { task.cancel() }
  }

  /// Resume the continuation exactly once; later calls are no-ops.
  func finish(_ result: Result<Data, Error>) {
    lock.lock()
    if didResume {
      lock.unlock()
      return
    }
    didResume = true
    let task = timeoutTask
    photoToken = nil
    errorToken = nil
    timeoutTask = nil
    lock.unlock()
    task?.cancel()
    continuation.resume(with: result)
  }
}
