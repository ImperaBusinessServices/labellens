import Foundation

/// User's personal health profile, used to personalize verdicts (e.g.
/// flagging an allergen or a medication interaction). Kept on-device only -
/// never sent anywhere except as part of a single verdict request
/// (see VerdictClient.getVerdict).
struct HealthProfile: Codable, Equatable {
  var allergies: [String] = []
  var medications: [String] = []
  var conditions: [String] = []
  var dietGoals: [String] = []

  static let empty = HealthProfile()
}

/// Local persistence for v1: a JSON blob in UserDefaults, on the PHONE only.
///
/// NOTE: UserDefaults is not encrypted at rest. Keychain would be more
/// appropriate if this profile ever holds anything more sensitive, or if
/// LabelLens stops being personal-use-only - not doing that here to avoid
/// over-engineering v1.
enum HealthProfileStore {
  private static let storageKey = "com.labellens.healthProfile"

  static func load() -> HealthProfile {
    guard let data = UserDefaults.standard.data(forKey: storageKey) else {
      return .empty
    }
    do {
      return try JSONDecoder().decode(HealthProfile.self, from: data)
    } catch {
      return .empty
    }
  }

  static func save(_ profile: HealthProfile) {
    do {
      let data = try JSONEncoder().encode(profile)
      UserDefaults.standard.set(data, forKey: storageKey)
    } catch {
      #if DEBUG
      NSLog("[LabelLens] Failed to save HealthProfile: \(error)")
      #endif
    }
  }
}
