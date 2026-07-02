import Foundation

/// Result of an AI verdict on a captured product/ingredient label.
struct Verdict: Codable {
  let productName: String
  /// One of "good" | "caution" | "avoid".
  let status: String
  let reason: String
  let personalFlag: String?
  /// "Not medical advice" line the server always attaches. Optional so
  /// decoding still succeeds if it's ever absent.
  let disclaimer: String?
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

/// Shared secret that must match LABELLENS_SHARED_SECRET on the server.
/// Keith: paste the SAME long random value you set in the server's .env here.
/// Sent as "Authorization: Bearer <secret>" so strangers can't hit the endpoint.
let verdictSharedSecret = "REPLACE-WITH-YOUR-SHARED-SECRET"

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

    // The server reads snake_case top-level keys (image_base64, profile).
    // Without this mapping Swift sends imageBase64/healthProfile and every
    // request fails with 400. The nested HealthProfile field names already
    // match the server, so only these two need remapping.
    enum CodingKeys: String, CodingKey {
      case imageBase64 = "image_base64"
      case healthProfile = "profile"
    }
  }

  func getVerdict(photoJPEG: Data, healthProfile: HealthProfile) async throws -> Verdict {
    // Catch the un-replaced placeholder early with a clear error, instead of
    // letting it parse as a valid URL and fail later with an opaque DNS error.
    guard !verdictServerURL.contains("REPLACE-WITH"),
          let url = URL(string: verdictServerURL) else {
      throw VerdictClientError.invalidServerURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(verdictSharedSecret)", forHTTPHeaderField: "Authorization")

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
