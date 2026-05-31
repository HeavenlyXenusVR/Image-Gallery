import base64
import binascii
import hashlib
import hmac
import logging
import secrets
from typing import Any

from fastapi import HTTPException, Request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

_auth_log = logging.getLogger(__name__)


TOKEN_SALT = "image_gallery_api_token"
SESSION_COOKIE_NAME = "image_gallery_session"
PBKDF2_ITERATIONS = 260_000


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITERATIONS)
    return f"pbkdf2_sha256${PBKDF2_ITERATIONS}${base64.b64encode(salt).decode()}${base64.b64encode(digest).decode()}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        algorithm, iterations, salt_b64, digest_b64 = encoded.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(digest_b64)
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, int(iterations))
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError, binascii.Error):
        # Expected for malformed or legacy hashes — not a bug.
        return False
    except Exception as exc:
        _auth_log.warning("Unexpected error during password verification: %s", exc)
        return False


def issue_token(secret_key: str, user: dict[str, Any]) -> str:
    serializer = URLSafeTimedSerializer(secret_key, salt=TOKEN_SALT)
    return serializer.dumps({"id": user["id"], "username": user["username"], "display_name": user.get("display_name")})


def verify_token(token: str | None, secret_key: str, max_age_seconds: int) -> dict[str, Any] | None:
    if not token:
        return None
    serializer = URLSafeTimedSerializer(secret_key, salt=TOKEN_SALT)
    try:
        data = serializer.loads(token, max_age=max_age_seconds)
    except (BadSignature, SignatureExpired):
        return None
    return data if isinstance(data, dict) else None


def extract_bearer_token(request: Request) -> str | None:
    header = str(request.headers.get("authorization") or "").strip()
    if header.lower().startswith("bearer "):
        token = header[7:].strip()
        if token:
            return token
    cookie_token = str(request.cookies.get(SESSION_COOKIE_NAME) or "").strip()
    return cookie_token or None


def require_auth(request: Request, secret_key: str, max_age_seconds: int) -> dict[str, Any]:
    auth = verify_token(extract_bearer_token(request), secret_key, max_age_seconds)
    if not auth:
        raise HTTPException(status_code=401, detail="Login required")
    return auth
