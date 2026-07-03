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

// verdictServerURL and verdictSharedSecret live in Secrets.swift — a
// git-ignored file, because this repo is PUBLIC and the real secret must
// never be committed. Copy Secrets.swift.example to Secrets.swift and fill
// in the real values (CI writes it from GitHub Actions secrets instead).

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
    // Catch un-replaced placeholders early with a clear error, instead of an
    // opaque DNS failure (URL) or a mystery 401 from the server (secret).
    guard !verdictServerURL.contains("REPLACE-WITH"),
          !verdictSharedSecret.contains("REPLACE-WITH"),
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
