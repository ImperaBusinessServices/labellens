# LabelLens

LabelLens is a personal app for Keith: point Meta Ray-Ban Display glasses at a food or medication label, and LabelLens scans it and shows a personalized verdict — good, caution, or avoid — right on the lens, based on Keith's own health profile.

## Repo layout

- `ios/` — the iOS app that runs on the glasses' companion phone and drives what shows up on the display. (Not created yet — see Status below.)
- `server/` — the backend that does the label scanning/lookup and decides the verdict. (Not created yet.)
- `.github/` — GitHub Actions automation, including the workflow that builds and ships the iOS app to TestFlight without needing a Mac (see `.github/workflows/ios-testflight.yml`).
- `fastlane/` — configuration for fastlane, the tool that handles iOS app signing and uploading to TestFlight.

## Status: Phase 1 scaffolding — not yet buildable or runnable

This repo currently only has pipeline and config scaffolding. Nothing here compiles or runs yet. Specifically:

- There is no Xcode project in `ios/` yet, so the CI workflow has nothing to build.
- The one-time signing bootstrap (fastlane match, non-readonly) hasn't been run, so even once there's an app, the pipeline can't sign it yet.
- There is no `server/` code yet and nothing is deployed, so there's no backend for the app to talk to.

In short: don't expect to check this out and get a working app. This is the plumbing, laid down first so later phases can plug into it.

## Next steps (the plan)

1. **Phase 1 (this repo, now):** CI/CD scaffolding and docs — done.
2. **Phase 2:** Test the camera and display plumbing on the real Meta Ray-Ban Display glasses — confirm we can capture an image and push text back to the lens.
3. **Phase 3:** Get the backend running on an AWS EC2 server, so there's something for the app to actually call.
4. **Phase 4:** Build the profile setup screen, so Keith can enter the health info that personalizes the verdicts.
5. **Phase 5:** End-to-end test — scan a real label on the glasses and confirm the right verdict shows up on the lens.

## How the build pipeline will work (once bootstrapped)

Keith doesn't own a Mac, so this project is set up to build and ship the iOS app entirely through GitHub Actions, which can rent a temporary Mac to do the compile:

1. A push to `main` triggers `.github/workflows/ios-testflight.yml` on a macOS GitHub Actions runner.
2. The workflow uses fastlane match to pull down the app's signing certificate and provisioning profile (stored encrypted in a private repo, referenced only through GitHub secrets — never committed here).
3. Fastlane builds the app and uploads it to TestFlight, where Keith can install it on his phone like any beta app.

The workflow file has detailed comments marking exactly which one-time manual step (the signing bootstrap) has to happen before any of this works for real.
