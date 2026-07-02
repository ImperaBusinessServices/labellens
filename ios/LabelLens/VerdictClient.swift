import Foundation

/// Result of an AI verdict on a captured product/ingredient label.
struct Verdict: Codable {
  let productName: String
  /// One of "good" | "caution" | "avoid".
  let status: String
  let reason: String
  let personalFlag: String?
}

enum VerdictClientError: Error {
  case invalidServerURL
  case networkFailure(Error)
  case invalidResponse
  case serverError(statusCode: Int)
  case decodingFailure(Error)
  case encodingFailure(Error)
}

/// Placeholder backend address. Keith: replace this with your EC2 box's
/// address once it's up (e.g. "https://12.34.56.78/verdict" or a real
/// domain). Left as a plain constant (not a Info.plist key) so it's easy to
/// find and edit in one place for v1.
let verdictServerURL = "https://REPLACE-WITH-YOUR-EC2-ADDRESS.example.com/verdict"

/// Plain URLSession HTTP client. Sends the captured label photo (as base64
/// inside a JSON body, to keep this simple for v1 rather than building
/// multipart/form-data) plus the user's HealthProfile, and decodes the
/// backend's JSON verdict.
///
/// Privacy note: never log the photo bytes, the encoded request body, or the
/// HealthProfile contents - only log high-level error cases.
struct VerdictClient {

  private struct RequestBody: Codable {
    let imageBase64: String
    let healthProfile: HealthProfile
  }

  func getVerdict(photoJPEG: Data, healthProfile: HealthProfile) async throws -> Verdict {
    guard let url = URL(string: verdictServerURL) else {
      throw VerdictClientError.invalidServerURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = RequestBody(
      imageBase64: photoJPEG.base64EncodedString(),
      healthProfile: healthProfile
    )

    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw VerdictClientError.encodingFailure(error)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw VerdictClientError.networkFailure(error)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw VerdictClientError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw VerdictClientError.serverError(statusCode: httpResponse.statusCode)
    }

    do {
      return try JSONDecoder().decode(Verdict.self, from: data)
    } catch {
      throw VerdictClientError.decodingFailure(error)
    }
  }
}
