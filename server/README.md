# LabelLens verdict server

1. Install dependencies: `pip install -r requirements.txt`
2. Copy `.env.example` to `.env`. Paste your real Anthropic API key into `ANTHROPIC_API_KEY`, and set `LABELLENS_SHARED_SECRET` to a strong random value (`python -c "import secrets; print(secrets.token_urlsafe(32))"`). Put that **same** secret in the iOS app (`VerdictClient.swift`). **Never commit `.env`** — it must stay out of git.
3. Run it locally for testing: `python app.py` (starts on `http://127.0.0.1:5000`). You can also use `flask run` if you prefer.
4. Test it with a POST to `/verdict`. You must send the shared secret as a header, and the base64 must be on a single line (no wrapping):

   ```
   curl -X POST http://127.0.0.1:5000/verdict \
     -H "Authorization: Bearer $LABELLENS_SHARED_SECRET" \
     -H "Content-Type: application/json" \
     -d '{"image_base64": "<base64 photo, no line breaks>", "profile": {"allergies": [], "medications": [], "conditions": [], "dietGoals": []}}'
   ```

   If you generate the base64 with the `base64` CLI, use `base64 -w 0` (or pipe through `tr -d '\n'`) so it isn't wrapped at 76 chars. It returns a verdict JSON object, or a plain error JSON on failure. Requests without the correct `Authorization` header get `401 Unauthorized`.

**Security note:** the server refuses every request unless `LABELLENS_SHARED_SECRET` is set and matches — so an unconfigured server is locked down, not left open.

**Eventually running this on the EC2 box:** don't leave it running via `python app.py` — that dev server stops the moment you close the terminal or the box reboots. Put it behind a real process manager instead (`gunicorn` running the Flask app, kept alive by `systemd` or `pm2`). Serve it over **HTTPS with a valid certificate** (a real domain/subdomain + Let's Encrypt on the nginx vhost) — iOS App Transport Security will refuse plain HTTP or self-signed endpoints, and the payload is sensitive health data that must not cross the internet in cleartext. A bare-IP `https://` URL can't get a normal certificate, so use a hostname. Add an nginx `limit_req` zone as a second layer of rate limiting on top of the shared secret. The `.env` file (with the real key + secret) lives only on the EC2 box, never in git. That's a "later" task, not tonight's.
</content>
