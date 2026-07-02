# LabelLens

LabelLens is a personal app for Keith: point Meta Ray-Ban Display glasses at a food or medication label, and LabelLens scans it and shows a personalized verdict — good, caution, or avoid — right on the lens, based on Keith's own health profile.

## Repo layout

- `ios/LabelLens/` — the real Swift source for the iOS app that runs on the glasses' companion phone: captures a photo, calls the verdict server, and renders the result on the lens. The Swift files exist, but there is no `.xcodeproj` wrapper yet — that gets generated once this is opened in Xcode on a Mac.
- `server/` — a working Flask app (`app.py`) that holds the Claude API key, receives a photo + health profile, and returns a structured verdict. Runnable locally today (`python app.py`), not yet deployed anywhere.
- `.github/` — GitHub Actions automation, including the workflow that builds and ships the iOS app to TestFlight without needing a Mac (see `.github/workflows/ios-testflight.yml`).
- `fastlane/` — configuration for fastlane, the tool that handles iOS app signing and uploading to TestFlight.

## Status: Phase 1 scaffolding — not yet buildable or runnable

The real source code exists for both the app and the server, but nothing has been compiled or deployed yet. Specifically:

- `ios/LabelLens/` has real Swift files (app entry point, camera capture, glasses display rendering, networking, health profile, profile setup screen) grounded against Meta's official sample code — but there is no `.xcodeproj` yet, so nothing can compile until this is opened in Xcode on a Mac and a project is created around these files.
- Two small pieces of the iOS code are marked with TODO comments because they couldn't be confirmed without a real compiler: the exact color-coding API for the verdict card (falls back to plain text wording for now, which works fine) and whether an icon exists for the "Scan" button (currently unset, also fine).
- `server/app.py` is a complete, syntax-checked Flask app you can run locally right now with a real Anthropic API key in a local `.env` file — see `server/README.md`.
- The one-time signing bootstrap (fastlane match, non-readonly) hasn't been run, so the CI pipeline can't sign/ship a build yet even once there's an Xcode project.
- The server isn't deployed anywhere yet (Phase 3).

In short: the code is real and was checked for correctness against Meta's actual SDK, but you can't build-and-run the iOS app without a Mac, and the server isn't live yet. This is genuine Phase 1 progress, not just plumbing.

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
