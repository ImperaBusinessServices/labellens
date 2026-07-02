"""
LabelLens Phase-1 verdict server.

One job: hold the real Anthropic API key server-side (never on the phone),
receive a product photo + health profile from the iOS app, ask Claude to
read the label and produce a personalized verdict, and return clean JSON.

Run locally with `flask run` or `python app.py` (see README.md).
"""

import base64
import binascii
import hmac
import logging
import os

from dotenv import load_dotenv
from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

import anthropic

# Load ANTHROPIC_API_KEY (and anything else in .env) for local dev.
# On the EC2 box this can instead be a real environment variable set by
# the process manager -- load_dotenv() is a no-op if there's no .env file.
load_dotenv()

# --------------------------------------------------------------------------
# Logging: never log request bodies (they contain the photo + health profile),
# and never log the API key. Only log high-level, non-sensitive events.
# --------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("labellens")

app = Flask(__name__)

# The current fast/cheap vision-capable Claude model for this use case.
# TODO: verify this exact model id string against the current Anthropic
# model list (https://docs.anthropic.com/en/docs/about-claude/models) before
# relying on it in production -- model ids are occasionally retired/renamed.
MODEL_NAME = "claude-haiku-4-5-20251001"

MAX_IMAGE_BYTES = 5 * 1024 * 1024  # 5 MB, generous for a label photo

# Reject oversized request bodies (413) before Flask/Werkzeug buffers the
# whole thing into memory for request.get_json() -- the MAX_IMAGE_BYTES
# check below only runs after the body has already been fully parsed, so
# without this a client could send an arbitrarily large body to exhaust
# server memory. ~7 MB covers a 5 MB image after base64 encoding overhead
# (~33%) plus the rest of the JSON payload (profile fields, etc).
app.config["MAX_CONTENT_LENGTH"] = 7 * 1024 * 1024

DISCLAIMER = "This is general information, not medical advice."

# Shared secret the iOS app must present so strangers who find the public
# EC2 URL can't spend our Anthropic money. Set LABELLENS_SHARED_SECRET in the
# environment (and the same value in the app). If it's unset the endpoint is
# locked down (every request gets 401) rather than left open by accident.
SHARED_SECRET = os.environ.get("LABELLENS_SHARED_SECRET", "")

ALLOWED_IMAGE_MEDIA_TYPES = {
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/gif",
}

VERDICT_STATUSES = ("good", "caution", "avoid")

# --------------------------------------------------------------------------
# Anthropic client. Reads ANTHROPIC_API_KEY from the environment itself --
# we never read, print, or otherwise touch the key value in this file.
# --------------------------------------------------------------------------
_anthropic_client = None


def get_anthropic_client():
    """Lazily create the Anthropic client so a missing key fails per-request
    (with a clean JSON error) instead of crashing the whole server on boot."""
    global _anthropic_client
    if _anthropic_client is None:
        if not os.environ.get("ANTHROPIC_API_KEY"):
            raise RuntimeError("ANTHROPIC_API_KEY is not set")
        # anthropic.Anthropic() reads ANTHROPIC_API_KEY from the environment
        # on its own; we deliberately do not pass the value through our code.
        # Keep the server-side wall-clock inside what the phone will wait for.
        # The iOS URLSession client gives up after ~60s; the SDK default is a
        # 10-minute timeout with 2 retries (~30 min worst case), which would
        # pin a worker long after the phone has already stopped listening.
        _anthropic_client = anthropic.Anthropic(timeout=25.0, max_retries=1)
    return _anthropic_client


def is_authorized(req):
    """True only if the request carries the correct shared secret. Uses a
    constant-time compare so timing can't be used to guess the secret."""
    if not SHARED_SECRET:
        return False
    header = req.headers.get("Authorization", "")
    prefix = "Bearer "
    if not header.startswith(prefix):
        return False
    presented = header[len(prefix):]
    return hmac.compare_digest(presented, SHARED_SECRET)


# --------------------------------------------------------------------------
# Tool definition for structured output. Asking Claude to call this tool
# forces a response that matches the Verdict shape exactly, instead of
# hoping the model returns clean JSON in prose.
# --------------------------------------------------------------------------
VERDICT_TOOL = {
    "name": "report_verdict",
    "description": (
        "Report the personalized verdict for the product label shown in the "
        "image, based on the user's health profile."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "productName": {
                "type": "string",
                "description": "The product name as read from the label.",
            },
            "status": {
                "type": "string",
                "enum": list(VERDICT_STATUSES),
                "description": (
                    "Overall verdict for this user: 'good' (fine for them), "
                    "'caution' (mixed / worth a second look), or 'avoid' "
                    "(conflicts with their profile)."
                ),
            },
            "reason": {
                "type": "string",
                "description": (
                    "One sentence, plain English, explaining the verdict."
                ),
            },
            "personalFlag": {
                "type": ["string", "null"],
                "description": (
                    "A specific personal warning tied to the user's profile "
                    "(e.g. an allergen or medication interaction), or null "
                    "if there isn't one."
                ),
            },
        },
        "required": ["productName", "status", "reason", "personalFlag"],
        "additionalProperties": False,
    },
    # Guarantees tool_use.input validates exactly against the schema above.
    "strict": True,
}


def build_profile_summary(profile):
    """Turn the profile dict into a short, readable block for the prompt."""
    allergies = profile.get("allergies") or []
    medications = profile.get("medications") or []
    conditions = profile.get("conditions") or []
    diet_goals = profile.get("dietGoals") or []

    def fmt(label, items):
        if not items:
            return f"{label}: none listed"
        return f"{label}: {', '.join(str(i) for i in items)}"

    return "\n".join(
        [
            fmt("Allergies", allergies),
            fmt("Medications", medications),
            fmt("Medical conditions", conditions),
            fmt("Diet goals", diet_goals),
        ]
    )


def error_response(message, status_code):
    """A clean error JSON body with no leaked internals (no stack traces,
    no API key fragments, no raw exception text)."""
    return jsonify({"error": message}), status_code


@app.route("/verdict", methods=["POST"])
def verdict():
    if not is_authorized(request):
        return error_response("Unauthorized.", 401)

    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return error_response("Request body must be JSON.", 400)

    image_base64 = body.get("image_base64")
    profile = body.get("profile")

    if not isinstance(image_base64, str) or not image_base64.strip():
        return error_response("image_base64 is required and must be a string.", 400)

    if not isinstance(profile, dict):
        return error_response("profile is required and must be an object.", 400)

    for field in ("allergies", "medications", "conditions", "dietGoals"):
        if field in profile and not isinstance(profile[field], list):
            return error_response(f"profile.{field} must be an array.", 400)

    # Strip a data URL prefix if the client sent one, e.g. "data:image/jpeg;base64,...."
    media_type = "image/jpeg"
    raw_b64 = image_base64
    if raw_b64.startswith("data:") and ";base64," in raw_b64:
        header, raw_b64 = raw_b64.split(";base64,", 1)
        candidate_media_type = header[len("data:"):]
        if candidate_media_type in ALLOWED_IMAGE_MEDIA_TYPES:
            media_type = candidate_media_type
        else:
            # A data-URL header was present but names a type Claude won't
            # accept -- reject clearly here instead of silently relabeling it
            # jpeg and getting a confusing error back from the vision API.
            return error_response("Unsupported image type.", 400)

    # Some base64 encoders wrap lines at 76 chars; validate=True rejects any
    # whitespace, so strip it first. The real iOS client sends a single line,
    # but this keeps the manual README test (and other callers) from failing.
    raw_b64 = "".join(raw_b64.split())

    try:
        decoded = base64.b64decode(raw_b64, validate=True)
    except (binascii.Error, ValueError):
        return error_response("image_base64 is not valid base64.", 400)

    if len(decoded) == 0:
        return error_response("image_base64 decoded to an empty image.", 400)
    if len(decoded) > MAX_IMAGE_BYTES:
        return error_response("Image is too large.", 400)

    profile_summary = build_profile_summary(profile)

    instruction = (
        "You are looking at a photo of a food or supplement product label. "
        "Read the label (product name, ingredients, and any nutrition or "
        "warning info visible) and compare it against this user's health "
        "profile:\n\n"
        f"{profile_summary}\n\n"
        "Then call the report_verdict tool with your personalized verdict. "
        "Rules:\n"
        "- productName: the product name as printed on the label. If it "
        "genuinely cannot be read, use \"Unknown product\".\n"
        "- status: \"avoid\" if the label conflicts with an allergy, "
        "medication, or condition in the profile; \"caution\" if there is a "
        "plausible but less certain concern, or the diet goals aren't a "
        "great match; \"good\" if nothing in the profile is a concern.\n"
        "- reason: one plain-English sentence a non-expert can understand.\n"
        "- personalFlag: a short, specific warning tied directly to the "
        "user's profile (e.g. \"Contains peanuts\" for a peanut allergy), "
        "or null if there is no specific personal concern.\n"
        "Only use the report_verdict tool -- do not respond in plain text."
    )

    try:
        client = get_anthropic_client()
    except RuntimeError:
        logger.error("ANTHROPIC_API_KEY is not configured")
        return error_response("Server is not configured correctly.", 500)

    try:
        response = client.messages.create(
            model=MODEL_NAME,
            max_tokens=1024,
            tools=[VERDICT_TOOL],
            tool_choice={"type": "tool", "name": "report_verdict"},
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": raw_b64,
                            },
                        },
                        {"type": "text", "text": instruction},
                    ],
                }
            ],
        )
    except anthropic.AuthenticationError:
        logger.error("Anthropic API rejected our credentials")
        return error_response("Server is not configured correctly.", 500)
    except anthropic.RateLimitError:
        logger.warning("Anthropic API rate limit hit")
        return error_response("The service is busy right now. Please try again.", 503)
    except anthropic.APIConnectionError:
        logger.error("Could not reach the Anthropic API")
        return error_response("Could not reach the verdict service. Please try again.", 502)
    except anthropic.APIStatusError as e:
        logger.error("Anthropic API returned an error status: %s", e.status_code)
        return error_response("The verdict service returned an error.", 502)
    except anthropic.APIError:
        logger.error("Unexpected Anthropic API error")
        return error_response("The verdict service returned an error.", 502)

    verdict_data = extract_verdict(response)
    if verdict_data is None:
        logger.error("Claude response did not include a valid report_verdict tool call")
        return error_response("Could not produce a verdict for this image.", 502)

    verdict_data["disclaimer"] = DISCLAIMER
    return jsonify(verdict_data), 200


def extract_verdict(response):
    """Pull and validate the report_verdict tool_use block out of the
    Claude response. Returns a plain dict on success, or None if the
    response doesn't contain a usable tool call."""
    for block in response.content:
        if getattr(block, "type", None) != "tool_use":
            continue
        if block.name != "report_verdict":
            continue

        tool_input = block.input
        if not isinstance(tool_input, dict):
            return None

        product_name = tool_input.get("productName")
        status = tool_input.get("status")
        reason = tool_input.get("reason")
        personal_flag = tool_input.get("personalFlag")

        if not isinstance(product_name, str) or not product_name.strip():
            return None
        if status not in VERDICT_STATUSES:
            return None
        if not isinstance(reason, str) or not reason.strip():
            return None
        if personal_flag is not None and not isinstance(personal_flag, str):
            return None

        return {
            "productName": product_name,
            "status": status,
            "reason": reason,
            "personalFlag": personal_flag,
        }

    return None


@app.errorhandler(404)
def not_found(_e):
    return error_response("Not found.", 404)


@app.errorhandler(405)
def method_not_allowed(_e):
    return error_response("Method not allowed.", 405)


@app.errorhandler(Exception)
def handle_unexpected_error(e):
    # Let real HTTP exceptions (e.g. 413 Request Entity Too Large from
    # MAX_CONTENT_LENGTH, or 400/415) reach the client with their true status
    # code instead of being masked as a generic 500. Without this, an oversized
    # upload returns a misleading "Something went wrong." 500.
    if isinstance(e, HTTPException):
        return error_response(e.description or e.name, e.code)
    # Catch-all so we never leak a stack trace or internal exception text.
    logger.exception("Unhandled error while processing request")
    return error_response("Something went wrong.", 500)


if __name__ == "__main__":
    # Flask's built-in dev server -- fine for local testing, not for
    # production use. See README.md for how this eventually runs on EC2.
    app.run(host="127.0.0.1", port=5000, debug=False)
