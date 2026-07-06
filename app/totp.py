"""Minimal RFC 6238 TOTP (stdlib-only — no pyotp/qrcode dependency).

Enrollment shows the raw secret + otpauth:// URI for manual entry into an
authenticator app rather than rendering a QR code image, since generating one
correctly would require pulling in a QR-encoding library for a single feature.
"""

import base64
import hashlib
import hmac
import secrets
import struct
from urllib.parse import quote

DIGITS = 6
PERIOD_SECONDS = 30


def generate_secret() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode("ascii").rstrip("=")


def _pad_secret(secret: str) -> str:
    cleaned = secret.strip().upper().replace(" ", "")
    return cleaned + "=" * (-len(cleaned) % 8)


def _hotp(secret: str, counter: int) -> str:
    key = base64.b32decode(_pad_secret(secret), casefold=True)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code_int = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % (10 ** DIGITS)
    return str(code_int).zfill(DIGITS)


def current_code(secret: str, *, at: float) -> str:
    return _hotp(secret, int(at // PERIOD_SECONDS))


def verify_code(secret: str, code: str, *, at: float, window: int = 1) -> bool:
    digits_only = "".join(ch for ch in str(code or "") if ch.isdigit())
    if len(digits_only) != DIGITS:
        return False
    counter = int(at // PERIOD_SECONDS)
    return any(
        hmac.compare_digest(_hotp(secret, counter + offset), digits_only)
        for offset in range(-window, window + 1)
    )


def provisioning_uri(secret: str, *, account_name: str, issuer: str = "Image Gallery") -> str:
    label = quote(f"{issuer}:{account_name}")
    query = f"secret={secret}&issuer={quote(issuer)}&algorithm=SHA1&digits={DIGITS}&period={PERIOD_SECONDS}"
    return f"otpauth://totp/{label}?{query}"


def generate_recovery_codes(count: int = 8) -> list[str]:
    return [f"{secrets.token_hex(3)}-{secrets.token_hex(3)}" for _ in range(count)]
