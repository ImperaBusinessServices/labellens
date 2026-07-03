import SwiftUI

/// Minimal v1 profile setup screen - this runs on the iPHONE (SwiftUI), not
/// the glasses lens (that's DisplayService/MWDATDisplay). Free-text,
/// comma-separated fields for each list. Not polished - just enough for
/// Keith to fill in his own profile once from his phone.
struct ProfileSetupView: View {
  @State private var allergiesText: String = ""
  @State private var medicationsText: String = ""
  @State private var conditionsText: String = ""
  @State private var dietGoalsText: String = ""
  @State private var didSave = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Allergies") {
          TextField("Comma-separated, e.g. peanuts, shellfish", text: $allergiesText)
        }
        Section("Medications") {
          TextField("Comma-separated, e.g. metformin", text: $medicationsText)
        }
        Section("Conditions") {
          TextField("Comma-separated, e.g. diabetes", text: $conditionsText)
        }
        Section("Diet Goals") {
          TextField("Comma-separated, e.g. low-sodium, vegetarian", text: $dietGoalsText)
        }
        Section {
          Button("Save Profile") {
            save()
          }
          if didSave {
            Text("Saved.").foregroundColor(.secondary)
          }
        }
      }
      .navigationTitle("LabelLens Profile")
      .onAppear(perform: load)
      // Clear the "Saved." confirmation once the user edits again, so it
      // never implies unsaved edits are already saved. One modifier over all
      // four fields (so adding a field can't be forgotten), using the
      // one-parameter closure form that compiles on pre-iOS-17 targets.
      .onChange(of: [allergiesText, medicationsText, conditionsText, dietGoalsText]) { _ in
        didSave = false
      }
    }
  }

  private func load() {
    let profile = HealthProfileStore.load()
    allergiesText = profile.allergies.joined(separator: ", ")
    medicationsText = profile.medications.joined(separator: ", ")
    conditionsText = profile.conditions.joined(separator: ", ")
    dietGoalsText = profile.dietGoals.joined(separator: ", ")
  }

  private func save() {
    let profile = HealthProfile(
      allergies: splitList(allergiesText),
      medications: splitList(medicationsText),
      conditions: splitList(conditionsText),
      dietGoals: splitList(dietGoalsText)
    )
    HealthProfileStore.save(profile)
    didSave = true
  }

  private func splitList(_ text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
