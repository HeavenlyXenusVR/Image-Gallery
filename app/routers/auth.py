"""Registration, login/logout, email verification, and the session-cookie helpers they share."""

import html
import re
import secrets
from typing import Any
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import HTMLResponse

import app.main as main
from ..auth import SESSION_COOKIE_NAME, issue_token, require_auth
from ..emailer import EmailDeliveryError, send_verification_email
from ..schemas import EmailCodeRequest, EmailUpdateRequest, LoginRequest, RegisterRequest
from ._shared import _jsonable, _rate_limit

router = APIRouter()


def _verification_url(request: Request, token: str) -> str:
    url = str(request.url_for("verify_email"))
    # If the backend sees the request as HTTP but a trusted proxy already handles
    # TLS, force the link to https so the user gets a working URL.
    if _request_is_https(request) and url.startswith("http://"):
        url = "https://" + url[7:]
    return f"{url}?token={quote(str(token), safe='')}"


def _verification_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def _wants_json(request: Request) -> bool:
    accept = request.headers.get("accept", "")
    return "application/json" in accept and "text/html" not in accept


async def _send_verification_or_error(request: Request, user: dict[str, Any], email_token: str) -> bool:
    try:
        await send_verification_email(main.settings, user["email"], _verification_url(request, email_token), email_token)
        return True
    except EmailDeliveryError as exc:
        raise HTTPException(status_code=502, detail=f"Email verification could not be sent: {exc}") from None


async def _try_send_verification(request: Request, user: dict[str, Any], email_token: str) -> tuple[bool, str | None]:
    try:
        await send_verification_email(main.settings, user["email"], _verification_url(request, email_token), email_token)
        return True, None
    except EmailDeliveryError as exc:
        return False, str(exc)


def _verification_page(title: str, message: str, *, ok: bool) -> HTMLResponse:
    color = "#37c9a7" if ok else "#ff6b6b"
    return HTMLResponse(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        f"<title>{html.escape(title)}</title>"
        "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;"
        "font-family:Inter,system-ui,sans-serif;background:#10151f;color:#edf4ff}"
        "main{width:min(520px,calc(100vw - 32px));padding:28px;border:1px solid #273244;"
        "background:#151d2b;border-radius:8px}h1{margin:0 0 10px;font-size:1.5rem}"
        "p{color:#aab6c8;line-height:1.5}.badge{display:inline-block;margin-bottom:16px;"
        f"color:{color};font-weight:700}}a{{color:#7dd3fc}}</style></head><body><main>"
        f"<span class=\"badge\">{'Verified' if ok else 'Needs Attention'}</span>"
        f"<h1>{html.escape(title)}</h1><p>{html.escape(message)}</p>"
        f"<p><a href=\"{html.escape(main.settings.pages_public_url)}\">Return to Image Gallery</a></p>"
        "</main></body></html>"
    )


def _client_ip(request: Request) -> str:
    direct = main._clean_ip(request.client.host if request.client else "") or "unknown"
    if main._is_trusted_proxy(direct):
        cf_ip = main._clean_ip(request.headers.get("cf-connecting-ip"))
        if cf_ip:
            return cf_ip
        real_ip = main._clean_ip(request.headers.get("x-real-ip"))
        if real_ip:
            return real_ip
        forwarded = main._clean_ip(request.headers.get("x-forwarded-for"))
        if forwarded:
            return forwarded
    return direct


def _request_is_https(request: Request) -> bool:
    proto = str(request.headers.get("x-forwarded-proto") or "").split(",")[0].strip().lower()
    return request.url.scheme == "https" or proto == "https"


def _set_session_cookie(response: Response, token: str, request: Request) -> None:
    secure = _request_is_https(request)
    response.set_cookie(
        SESSION_COOKIE_NAME,
        token,
        max_age=main.settings.api_token_ttl_seconds,
        httponly=True,
        secure=secure,
        samesite="none" if secure else "lax",
        path="/",
    )


def _clear_session_cookie(response: Response, request: Request) -> None:
    secure = _request_is_https(request)
    response.delete_cookie(SESSION_COOKIE_NAME, path="/", secure=secure, samesite="none" if secure else "lax")


@router.post("/api/auth/register")
async def register(payload: RegisterRequest, request: Request, response: Response) -> dict[str, Any]:
    await _rate_limit(f"register:{_client_ip(request)}", limit=10, window_seconds=3600)
    email_token = _verification_code() if payload.email else None
    try:
        user = await main.db.register_user(payload.username, payload.password, payload.display_name, payload.email, email_token)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    except Exception as exc:
        if "Duplicate" in str(exc):
            raise HTTPException(status_code=409, detail="That username or email is already taken.") from None
        raise
    verification_sent = False
    email_error = None
    if user.get("email") and email_token:
        verification_sent, email_error = await _try_send_verification(request, user, email_token)
    token = issue_token(main.settings.session_secret, user)
    _set_session_cookie(response, token, request)
    return {
        "user": _jsonable(user),
        "token": token,
        "email_verification_sent": verification_sent,
        "email_error": email_error,
    }


@router.get("/api/auth/verify-email", name="verify_email")
async def verify_email(request: Request, token: str):
    user = await main.db.verify_email_by_token(token)
    if not user:
        if _wants_json(request):
            raise HTTPException(status_code=400, detail="Invalid or expired verification link.")
        return _verification_page("Verification Link Expired", "That Image Gallery verification link is invalid or has already been used. Sign in and resend verification from your account.", ok=False)
    if _wants_json(request):
        return {"ok": True, "user": _jsonable(user)}
    return _verification_page("Email Verified", f"{user.get('email') or 'Your email address'} is now verified for Image Gallery.", ok=True)


@router.post("/api/auth/resend-verification")
async def resend_verification(request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    await _rate_limit(f"resend-verification:{auth['id']}", limit=8, window_seconds=3600)
    user = await main.db.get_user(int(auth["id"]))
    if not user:
        raise HTTPException(status_code=404, detail="Account not found.")
    if not user.get("email"):
        raise HTTPException(status_code=400, detail="This account does not have an email address.")
    if user.get("email_verified_at"):
        return {"ok": True, "email_verification_sent": False, "already_verified": True}
    email_token = _verification_code()
    user = await main.db.issue_email_verification_token(int(auth["id"]), email_token)
    verification_sent = bool(user and await _send_verification_or_error(request, user, email_token))
    return {"ok": verification_sent, "email_verification_sent": verification_sent, "already_verified": False}


@router.post("/api/me/email")
async def update_email(payload: EmailUpdateRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    await _rate_limit(f"email-update:{auth['id']}", limit=8, window_seconds=3600)
    try:
        user = await main.db.update_user_email(int(auth["id"]), payload.email)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    verification_sent = False
    if user and user.get("email"):
        email_token = _verification_code()
        user = await main.db.issue_email_verification_token(int(auth["id"]), email_token)
        verification_sent = bool(user and await _send_verification_or_error(request, user, email_token))
    return {"ok": True, "user": _jsonable(user), "email_verification_sent": verification_sent}


@router.post("/api/me/email/verify")
async def verify_email_code(payload: EmailCodeRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    await _rate_limit(f"email-verify:{auth['id']}", limit=20, window_seconds=3600)
    code = re.sub(r"\D+", "", str(payload.code or ""))[:12]
    if not code:
        raise HTTPException(status_code=400, detail="Enter the verification code from your email.")
    user = await main.db.verify_email_code(int(auth["id"]), code)
    if not user:
        raise HTTPException(status_code=400, detail="Invalid verification code.")
    return {"ok": True, "user": _jsonable(user)}


@router.post("/api/auth/login")
async def login(payload: LoginRequest, request: Request, response: Response) -> dict[str, Any]:
    ip = _client_ip(request)
    username = (payload.username or "").strip()[:80]
    if await main.db.count_recent_failed_auth(username, ip) >= 8:
        raise HTTPException(status_code=429, detail="Too many failed login attempts. Try again later.")
    try:
        user = await main.db.authenticate_user(payload.username, payload.password)
    except ValueError as exc:
        await main.db.record_auth_attempt(username, ip, False)
        raise HTTPException(status_code=400, detail=str(exc)) from None
    await main.db.record_auth_attempt(username, ip, bool(user))
    if not user:
        raise HTTPException(status_code=401, detail="Invalid username or password.")
    token = issue_token(main.settings.session_secret, user)
    _set_session_cookie(response, token, request)
    return {"user": _jsonable(user), "token": token}


@router.post("/api/auth/logout")
async def logout(request: Request, response: Response) -> dict[str, Any]:
    _clear_session_cookie(response, request)
    return {"ok": True}

