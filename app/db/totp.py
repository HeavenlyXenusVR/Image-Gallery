"""TOTP two-factor authentication: enrollment, confirmation, login verification, disable."""

import json
import time
from typing import Any

from . import pg_compat as aiomysql

from ..auth import hash_password, verify_password
from ..totp import generate_recovery_codes, generate_secret, provisioning_uri, verify_code


def _decode_recovery_codes(raw: Any) -> list[str]:
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return []
    return list(raw) if isinstance(raw, list) else []


class TotpMixin:
    async def get_totp_status(self, user_id: int) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT totp_enabled_at, totp_recovery_codes FROM users WHERE id=%s", (user_id,))
                row = await cur.fetchone() or {}
        return {
            "enabled": bool(row.get("totp_enabled_at")),
            "recovery_codes_remaining": len(_decode_recovery_codes(row.get("totp_recovery_codes"))),
        }

    async def begin_totp_enrollment(self, user_id: int, username: str) -> dict[str, Any]:
        secret = generate_secret()
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                # Written eagerly but not "enabled" until confirm_totp_enrollment sees a
                # live code — an abandoned enrollment just leaves an unused secret behind.
                await cur.execute("UPDATE users SET totp_secret=%s, totp_enabled_at=NULL WHERE id=%s", (secret, user_id))
        self._invalidate_user_cache(user_id)
        return {"secret": secret, "uri": provisioning_uri(secret, account_name=username)}

    async def confirm_totp_enrollment(self, user_id: int, code: str) -> list[str]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT totp_secret FROM users WHERE id=%s", (user_id,))
                row = await cur.fetchone()
        secret = row.get("totp_secret") if row else None
        if not secret:
            raise ValueError("Start 2FA setup first.")
        if not verify_code(secret, code, at=time.time()):
            raise ValueError("Incorrect code. Check your authenticator app and try again.")
        recovery_codes = generate_recovery_codes()
        hashed_codes = [hash_password(recovery_code) for recovery_code in recovery_codes]
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE users SET totp_enabled_at=CURRENT_TIMESTAMP, totp_recovery_codes=%s WHERE id=%s",
                    (json.dumps(hashed_codes), user_id),
                )
        self._invalidate_user_cache(user_id)
        return recovery_codes

    async def disable_totp(self, user_id: int, password: str) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT password_hash FROM users WHERE id=%s", (user_id,))
                row = await cur.fetchone()
        if not row or not verify_password(password, row["password_hash"]):
            raise ValueError("Incorrect password.")
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE users SET totp_secret=NULL, totp_enabled_at=NULL, totp_recovery_codes=NULL WHERE id=%s",
                    (user_id,),
                )
        self._invalidate_user_cache(user_id)

    async def totp_enabled_for(self, user_id: int) -> bool:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("SELECT totp_enabled_at FROM users WHERE id=%s", (user_id,))
                row = await cur.fetchone()
        return bool(row and row[0])

    async def verify_totp_or_recovery(self, user_id: int, code: str) -> bool:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT totp_secret, totp_enabled_at, totp_recovery_codes FROM users WHERE id=%s",
                    (user_id,),
                )
                row = await cur.fetchone()
        if not row or not row.get("totp_enabled_at") or not row.get("totp_secret"):
            return False
        if verify_code(row["totp_secret"], code, at=time.time()):
            return True
        stored_codes = _decode_recovery_codes(row.get("totp_recovery_codes"))
        stripped = str(code or "").strip()
        for index, hashed_code in enumerate(stored_codes):
            if verify_password(stripped, hashed_code):
                remaining = stored_codes[:index] + stored_codes[index + 1:]
                async with self.pool.acquire() as conn:
                    async with conn.cursor() as cur:
                        await cur.execute(
                            "UPDATE users SET totp_recovery_codes=%s WHERE id=%s",
                            (json.dumps(remaining), user_id),
                        )
                return True
        return False
