# Signing bootstrap — the one-time Apple step

This is the single fiddly part of shipping an iPhone app with no Mac. You do it
**once**. After it works, every future build signs and ships itself automatically.

In plain terms: before Apple lets an app onto a phone, it has to be "signed" with
a certificate that proves it's really from you. Normally you'd make that
certificate on a Mac. We do it in the cloud instead, on a rented Mac that GitHub
provides for free, driven entirely by a revocable Apple **API key** — never your
Apple password.

## The only thing Keith has to do by hand

**Create an App Store Connect API key** (this is a web page, no Mac needed):

1. Go to https://appstoreconnect.apple.com and sign in with the Steel Blade LLC
   Apple ID.
2. Click **Users and Access**, then the **Integrations** tab, then **App Store
   Connect API** in the sidebar.
3. Click the **+** to generate a new key. Name it `LabelLens CI`. For **Access**,
   choose **Admin** (match needs this to create certificates).
4. Click **Generate**. Then **download the key file** — it's a small `.p8` file.
   You can only download it once, so keep it.
5. On that same page, copy two IDs: the **Key ID** (next to the key you just
   made) and the **Issuer ID** (shown at the top of the Keys list).

Then hand Claude three things: the `.p8` file's contents, the Key ID, and the
Issuer ID. Claude does everything else (creates the private storage repo, sets
all the secrets, and runs the bootstrap). That `.p8` key can be revoked from this
same page at any time, so nothing permanent is exposed.

## What Claude does (no Mac, no Keith)

1. Create a **private** GitHub repo (e.g. `labellens-signing`) to hold the
   encrypted certificates. It never contains anything readable.
2. Set these Actions secrets on the `labellens` repo:
   - `APP_STORE_CONNECT_API_KEY_ID` — the Key ID
   - `APP_STORE_CONNECT_API_ISSUER_ID` — the Issuer ID
   - `APP_STORE_CONNECT_API_KEY_CONTENT` — the `.p8` contents, base64-encoded
   - `MATCH_GIT_URL` — HTTPS URL of the private signing repo
   - `MATCH_GIT_BASIC_AUTHORIZATION` — base64 of `username:personal-access-token`
     so the runner can push to the private signing repo
   - `MATCH_PASSWORD` — a long random passphrase that encrypts the signing repo
   - `VERDICT_SERVER_URL` and `LABELLENS_SHARED_SECRET` — needed later, for the
     TestFlight build (see the server setup), not for the bootstrap itself
3. Run the **Signing bootstrap (one-time)** workflow from the repo's Actions tab.
   It registers the App ID, enables the Associated Domains capability, creates
   the distribution certificate + provisioning profile, and pushes them into the
   private repo.
4. Run **iOS TestFlight** — it builds the signed app and uploads it to
   TestFlight, where it lands on Keith's iPhone like any beta app.

## Fallback: a friend's Mac (only if the cloud path fails)

The cloud bootstrap should work with just the API key. If Apple ever forces an
interactive step the cloud can't do, the fallback is to run the exact same
`fastlane bootstrap_signing` command once on any Mac. Notes for a
privacy-conscious friend lending his Mac:

- It runs **one** command from a script he can read start to finish first. No
  background installs, no daemons, nothing that stays running.
- It uses a **revocable API key**, not any Apple password, and touches nothing
  personal on his machine — no access to his Apple ID, files, or accounts.
- It creates a certificate in a temporary keychain and pushes an **encrypted**
  file to our own private repo. It doesn't phone home anywhere else.
- It's fully reversible: delete the temporary keychain and revoke the key, and
  no trace remains. Total time is a few minutes.

## Reproducibility notes

- There is no hand-made `.xcodeproj` in git — it's generated from
  `ios/project.yml` by XcodeGen on the runner. Edit `project.yml`, never a
  generated project.
- The Meta SDK version is pinned in `project.yml`
  (`packages.MetaWearablesDAT.exactVersion`), so builds are reproducible without
  a committed `Package.resolved`.
- The compile check (`ios-ci.yml`) needs none of the above — it builds unsigned
  for the simulator and proves the code compiles against the Meta SDK on every
  push.
