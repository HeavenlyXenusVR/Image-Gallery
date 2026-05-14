import os
import socket
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


ROOT_DIR = Path(__file__).resolve().parent.parent
load_dotenv(ROOT_DIR / ".env")
if os.getenv("GALLERY_LOAD_SHARED_MUSIC_ENV", "0").lower() in {"1", "true", "yes", "on"}:
    load_dotenv(ROOT_DIR.parent / "Music" / ".env", override=False)


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _env_csv(name: str) -> list[str]:
    return [item.strip().rstrip("/") for item in _env(name).split(",") if item.strip()]


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int_set(name: str) -> set[int]:
    values: set[int] = set()
    for item in _env(name).split(","):
        item = item.strip()
        if not item:
            continue
        try:
            values.add(int(item))
        except ValueError:
            continue
    return values


def _ai_provider(ai_api_key: str) -> str:
    preferred = _env("GALLERY_AI_PROVIDER")
    if preferred:
        normalized = preferred.lower()
        if normalized in {"openai", "ollama"}:
            return normalized
    if _env("GALLERY_OLLAMA_MODEL") or _env("GALLERY_OLLAMA_BASE_URL"):
        return "ollama"
    return "openai" if ai_api_key else "ollama"


def _db_host() -> str:
    explicit = _env("GALLERY_DB_HOST")
    if explicit:
        if explicit == "host.docker.internal":
            try:
                socket.gethostbyname(explicit)
            except OSError:
                return "127.0.0.1"
        return explicit
    inherited = _env("DB_HOST") or _env("MYSQL_HOST")
    if inherited and inherited != "host.docker.internal":
        return inherited
    return "127.0.0.1"


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_port: int
    db_user: str
    db_password: str
    db_schema: str
    db_pool_min_size: int
    db_pool_max_size: int
    db_pool_recycle_seconds: int
    db_connect_timeout_seconds: int
    db_query_timeout_seconds: int
    session_secret: str
    api_token_ttl_seconds: int
    cors_allowed_origins: list[str]
    trusted_hosts: list[str]
    pages_public_url: str
    uploads_dir: Path
    max_upload_bytes: int
    required_db_packet_bytes: int
    db_blob_chunk_bytes: int
    smtp_host: str
    smtp_port: int
    smtp_username: str
    smtp_password: str
    smtp_from_email: str
    smtp_use_tls: bool
    ai_enabled: bool
    ai_provider: str
    ai_api_key: str
    ai_base_url: str
    ai_model: str
    ollama_base_url: str
    ollama_model: str
    ai_timeout_seconds: int
    telegram_bot_token: str
    telegram_allowed_chat_ids: set[int]
    telegram_polling_enabled: bool

    @property
    def active_ai_base_url(self) -> str:
        return self.ollama_base_url if self.ai_provider == "ollama" else self.ai_base_url

    @property
    def active_ai_model(self) -> str:
        return self.ollama_model if self.ai_provider == "ollama" else self.ai_model


def load_settings() -> Settings:
    pages_url = _env("GALLERY_PAGES_PUBLIC_URL", "https://heavenlyxenusvr.github.io/Image-Gallery/")
    ai_api_key = _env("GALLERY_AI_API_KEY") or _env("OPENAI_API_KEY")
    ai_provider = _ai_provider(ai_api_key)
    ai_enabled_default = "true" if (ai_api_key or ai_provider == "ollama" or _env("GALLERY_OLLAMA_MODEL")) else "false"
    ai_enabled_raw = _env("GALLERY_AI_ENABLED", ai_enabled_default)
    return Settings(
        db_host=_db_host(),
        db_port=int(_env("GALLERY_DB_PORT", "3306")),
        db_user=_env("GALLERY_DB_USER") or _env("DB_USER") or _env("MYSQL_USER") or "botuser",
        db_password=_env("GALLERY_DB_PASSWORD") or _env("DB_PASSWORD") or _env("MYSQL_PASSWORD") or "bot_logins",
        db_schema=_env("GALLERY_DB_SCHEMA", "image_gallery"),
        db_pool_min_size=max(1, int(_env("GALLERY_DB_POOL_MIN_SIZE", "1"))),
        db_pool_max_size=max(2, int(_env("GALLERY_DB_POOL_MAX_SIZE", "8"))),
        db_pool_recycle_seconds=max(30, int(_env("GALLERY_DB_POOL_RECYCLE_SECONDS", "180"))),
        db_connect_timeout_seconds=max(3, int(_env("GALLERY_DB_CONNECT_TIMEOUT_SECONDS", "10"))),
        db_query_timeout_seconds=max(5, int(_env("GALLERY_DB_QUERY_TIMEOUT_SECONDS", "45"))),
        session_secret=_env("GALLERY_SESSION_SECRET", "change-this-gallery-secret"),
        api_token_ttl_seconds=int(_env("GALLERY_API_TOKEN_TTL_SECONDS", "1209600")),
        cors_allowed_origins=_env_csv("GALLERY_CORS_ALLOWED_ORIGINS"),
        trusted_hosts=_env_csv("GALLERY_TRUSTED_HOSTS"),
        pages_public_url=pages_url,
        uploads_dir=Path(_env("GALLERY_UPLOADS_DIR", str(ROOT_DIR / "uploads"))),
        max_upload_bytes=int(_env("GALLERY_MAX_UPLOAD_BYTES", str(500 * 1024 * 1024))),
        required_db_packet_bytes=int(_env("GALLERY_REQUIRED_DB_PACKET_BYTES", str(512 * 1024 * 1024))),
        db_blob_chunk_bytes=int(_env("GALLERY_DB_BLOB_CHUNK_BYTES", str(8 * 1024 * 1024))),
        smtp_host=_env("GALLERY_SMTP_HOST") or _env("SMTP_HOST"),
        smtp_port=int(_env("GALLERY_SMTP_PORT") or _env("SMTP_PORT") or "587"),
        smtp_username=_env("GALLERY_SMTP_USERNAME") or _env("SMTP_USERNAME"),
        smtp_password=_env("GALLERY_SMTP_PASSWORD") or _env("SMTP_PASSWORD"),
        smtp_from_email=_env("GALLERY_SMTP_FROM_EMAIL") or _env("SMTP_FROM_EMAIL") or _env("GALLERY_SMTP_USERNAME") or _env("SMTP_USERNAME"),
        smtp_use_tls=(_env("GALLERY_SMTP_USE_TLS") or _env("SMTP_USE_TLS") or "true").lower() not in {"0", "false", "no", "off"},
        ai_enabled=ai_enabled_raw.lower() not in {"0", "false", "no", "off"},
        ai_provider=ai_provider,
        ai_api_key=ai_api_key,
        ai_base_url=(_env("GALLERY_AI_BASE_URL") or _env("OPENAI_BASE_URL") or "https://api.openai.com/v1").rstrip("/"),
        ai_model=_env("GALLERY_AI_MODEL", "gpt-5.4-nano"),
        ollama_base_url=(_env("GALLERY_OLLAMA_BASE_URL", "http://127.0.0.1:11434")).rstrip("/"),
        ollama_model=_env("GALLERY_OLLAMA_MODEL", "qwen2.5vl:7b"),
        ai_timeout_seconds=max(10, int(_env("GALLERY_AI_TIMEOUT_SECONDS", "45"))),
        telegram_bot_token=_env("GALLERY_TELEGRAM_BOT_TOKEN") or _env("TELEGRAM_BOT_TOKEN"),
        telegram_allowed_chat_ids=_env_int_set("GALLERY_TELEGRAM_ALLOWED_CHAT_IDS") or _env_int_set("TELEGRAM_ALLOWED_CHAT_IDS"),
        telegram_polling_enabled=_env_bool("GALLERY_TELEGRAM_POLLING_ENABLED", bool(_env("GALLERY_TELEGRAM_BOT_TOKEN") or _env("TELEGRAM_BOT_TOKEN"))),
    )
