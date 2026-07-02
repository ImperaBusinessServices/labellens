# LabelLens verdict server

1. Install dependencies: `pip install -r requirements.txt`
2. Copy `.env.example` to `.env` and paste your real Anthropic API key into it. **Never commit `.env`** — it should stay out of git (add it to `.gitignore`).
3. Run it locally for testing: `python app.py` (starts on `http://127.0.0.1:5000`). You can also use `flask run` if you prefer.
4. Test it with a POST to `/verdict`, JSON body: `{"image_base64": "<base64 photo>", "profile": {"allergies": [], "medications": [], "conditions": [], "dietGoals": []}}`. It returns a verdict JSON object, or a plain error JSON on failure.

**Eventually running this on the EC2 box:** don't leave it running via `python app.py` — that dev server stops the moment you close the terminal or the box reboots. Put it behind a real process manager instead (e.g. `gunicorn` running the Flask app, kept alive by `systemd` or `pm2`), and put it behind the same nginx/reverse-proxy setup the other sites on the box already use, on its own port. The `.env` file (with the real key) lives only on the EC2 box, never in git. That's a "later" task, not tonight's.
