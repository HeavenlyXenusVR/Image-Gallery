import logging
import os
import secrets
import socket
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

_cfg_log = logging.getLogger(__name__)


ROOT_DIR = Path(__file__).resolve().parent.parent
load_dotenv(ROOT_DIR / ".env")
if os.getenv("GALLERY_LOAD_SHARED_MUSIC_ENV", "0").lower() in {"1", "true", "yes", "on"}:
    load_dotenv(ROOT_DIR.parent / "Music" / ".env", override=False)


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _env_or_file(name: str, default: str = "") -> str:
    value = _env(name)
    if value:
        return value
    file_path = _env(f"{name}_FILE")
    if file_path:
        try:
            return Path(file_path).read_text(encoding="utf-8").strip()
        except Exception as exc:
            _cfg_log.warning("Could not read secret file for %s (%s): %s", name, file_path, exc)
            return default
    return default


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


def _gemini_api_key() -> str:
    return _env_or_file("GALLERY_GEMINI_API_KEY") or _env_or_file("GEMINI_API_KEY") or _env_or_file("GOOGLE_API_KEY")


def _ai_provider(ai_api_key: str) -> str:
    preferred = _env("GALLERY_AI_PROVIDER").lower()
    if preferred:
        if preferred in {"gemini", "google", "google-gemini"}:
            return "gemini"
        if preferred in {"openai", "ollama", "local"}:
            return preferred
    # Vision should prefer Gemini when a Gemini/Google key or model is configured.
    if _gemini_api_key() or _env("GALLERY_GEMINI_MODEL") or _env("GEMINI_MODEL"):
        return "gemini"
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
    storage_backend: str
    max_upload_bytes: int
    media_page_limit: int
    max_tags_per_upload: int
    max_tag_length: int
    upload_rate_limit_per_hour: int
    analyze_rate_limit_per_hour: int
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
    ai_allow_taxonomy_creation: bool
    ai_auto_train_on_edit: bool
    ai_training_examples_limit: int
    ai_background_learning_enabled: bool
    ai_background_learning_interval_seconds: int
    ai_background_learning_batch_size: int
    ai_background_learning_stale_minutes: int
    ai_background_learning_error_retry_minutes: int
    ai_background_learning_autofill_confidence: float
    ai_background_learning_min_training_tags: int
    telegram_bot_token: str
    telegram_allowed_chat_ids: set[int]
    telegram_owner_chat_id: int | None
    telegram_polling_enabled: bool
    admin_discord_webhook_url: str
    digest_interval_hours: int

    @property
    def active_ai_base_url(self) -> str:
        return self.ollama_base_url if self.ai_provider == "ollama" else self.ai_base_url

    @property
    def active_ai_model(self) -> str:
        if self.ai_provider in {"gemini", "google", "google-gemini"}:
            return _env("GALLERY_GEMINI_MODEL") or _env("GEMINI_MODEL") or self.ai_model or "gemini-2.5-flash"
        return self.ollama_model if self.ai_provider == "ollama" else self.ai_model


def load_settings() -> Settings:
    pages_url = _env("GALLERY_PAGES_PUBLIC_URL", "https://heavenlyxenusvr.github.io/Image-Gallery/")
    ai_api_key = _env_or_file("GALLERY_AI_API_KEY") or _env_or_file("OPENAI_API_KEY")
    gemini_api_key = _gemini_api_key()
    ai_provider = _ai_provider(ai_api_key)
    ai_enabled_default = "true" if (ai_api_key or gemini_api_key or ai_provider in {"ollama", "gemini", "google", "google-gemini"} or _env("GALLERY_OLLAMA_MODEL")) else "false"
    ai_enabled_raw = _env("GALLERY_AI_ENABLED", ai_enabled_default)
    require_strong_secrets = _env_bool("GALLERY_REQUIRE_STRONG_SECRETS") or _env("GALLERY_ENV").lower() == "production"
    session_secret = _env("GALLERY_SESSION_SECRET")
    if require_strong_secrets and not session_secret:
        raise RuntimeError("GALLERY_SESSION_SECRET is required when GALLERY_ENV=production or GALLERY_REQUIRE_STRONG_SECRETS=true.")
    db_password = _env("GALLERY_DB_PASSWORD") or _env("DB_PASSWORD") or _env("MYSQL_PASSWORD")
    if require_strong_secrets and not db_password:
        raise RuntimeError("GALLERY_DB_PASSWORD, DB_PASSWORD, or MYSQL_PASSWORD is required in hardened mode.")
    storage_backend = _env("GALLERY_STORAGE_BACKEND", "database").lower()
    if storage_backend not in {"filesystem", "database"}:
        storage_backend = "database"
    return Settings(
        db_host=_db_host(),
        db_port=int(_env("GALLERY_DB_PORT", "3306")),
        db_user=_env("GALLERY_DB_USER") or _env("DB_USER") or _env("MYSQL_USER") or "botuser",
        db_password=db_password or "bot_logins",
        db_schema=_env("GALLERY_DB_SCHEMA", "image_gallery"),
        db_pool_min_size=max(1, int(_env("GALLERY_DB_POOL_MIN_SIZE", "1"))),
        db_pool_max_size=max(2, int(_env("GALLERY_DB_POOL_MAX_SIZE", "8"))),
        db_pool_recycle_seconds=max(30, int(_env("GALLERY_DB_POOL_RECYCLE_SECONDS", "180"))),
        db_connect_timeout_seconds=max(3, int(_env("GALLERY_DB_CONNECT_TIMEOUT_SECONDS", "10"))),
        db_query_timeout_seconds=max(5, int(_env("GALLERY_DB_QUERY_TIMEOUT_SECONDS", "45"))),
        session_secret=session_secret or secrets.token_urlsafe(32),
        api_token_ttl_seconds=int(_env("GALLERY_API_TOKEN_TTL_SECONDS", "1209600")),
        cors_allowed_origins=_env_csv("GALLERY_CORS_ALLOWED_ORIGINS"),
        trusted_hosts=_env_csv("GALLERY_TRUSTED_HOSTS"),
        pages_public_url=pages_url,
        uploads_dir=Path(_env("GALLERY_UPLOADS_DIR", str(ROOT_DIR / "uploads"))),
        storage_backend=storage_backend,
        max_upload_bytes=int(_env("GALLERY_MAX_UPLOAD_BYTES", str(500 * 1024 * 1024))),
        media_page_limit=max(1, min(200, int(_env("GALLERY_MEDIA_PAGE_LIMIT", "100")))),
        max_tags_per_upload=max(1, min(50, int(_env("GALLERY_MAX_TAGS_PER_UPLOAD", "12")))),
        max_tag_length=max(8, min(80, int(_env("GALLERY_MAX_TAG_LENGTH", "32")))),
        upload_rate_limit_per_hour=max(1, int(_env("GALLERY_UPLOAD_RATE_LIMIT_PER_HOUR", "60"))),
        analyze_rate_limit_per_hour=max(1, int(_env("GALLERY_ANALYZE_RATE_LIMIT_PER_HOUR", "120"))),
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
        ai_api_key=gemini_api_key if ai_provider in {"gemini", "google", "google-gemini"} else ai_api_key,
        ai_base_url=(_env("GALLERY_AI_BASE_URL") or _env("OPENAI_BASE_URL") or "https://api.openai.com/v1").rstrip("/"),
        ai_model=_env("GALLERY_GEMINI_MODEL") or _env("GEMINI_MODEL") or _env("GALLERY_AI_MODEL", "gemini-2.5-flash" if ai_provider in {"gemini", "google", "google-gemini"} else "gpt-4o-mini"),
        ollama_base_url=(_env("GALLERY_OLLAMA_BASE_URL", "http://127.0.0.1:11434")).rstrip("/"),
        ollama_model=_env("GALLERY_OLLAMA_MODEL", "qwen2.5vl:3b"),
        ai_timeout_seconds=max(10, int(_env("GALLERY_AI_TIMEOUT_SECONDS", "45"))),
        ai_allow_taxonomy_creation=_env_bool("GALLERY_AI_ALLOW_TAXONOMY_CREATION", True),
        ai_auto_train_on_edit=_env_bool("GALLERY_AI_AUTO_TRAIN_ON_EDIT", True),
        ai_training_examples_limit=max(0, min(1000, int(_env("GALLERY_AI_TRAINING_EXAMPLES_LIMIT", "300")))),
        ai_background_learning_enabled=_env_bool("GALLERY_AI_BACKGROUND_LEARNING_ENABLED", True),
        ai_background_learning_interval_seconds=max(15, int(_env("GALLERY_AI_BACKGROUND_LEARNING_INTERVAL_SECONDS", "180"))),
        ai_background_learning_batch_size=max(1, min(50, int(_env("GALLERY_AI_BACKGROUND_LEARNING_BATCH_SIZE", "8")))),
        ai_background_learning_stale_minutes=max(10, int(_env("GALLERY_AI_BACKGROUND_LEARNING_STALE_MINUTES", "720"))),
        ai_background_learning_error_retry_minutes=max(5, int(_env("GALLERY_AI_BACKGROUND_LEARNING_ERROR_RETRY_MINUTES", "30"))),
        ai_background_learning_autofill_confidence=max(0.45, min(0.99, float(_env("GALLERY_AI_BACKGROUND_LEARNING_AUTOFILL_CONFIDENCE", "0.88")))),
        ai_background_learning_min_training_tags=max(1, min(24, int(_env("GALLERY_AI_BACKGROUND_LEARNING_MIN_TRAINING_TAGS", "3")))),
        telegram_bot_token=_env("GALLERY_TELEGRAM_BOT_TOKEN") or _env("TELEGRAM_BOT_TOKEN"),
        telegram_allowed_chat_ids=_env_int_set("GALLERY_TELEGRAM_ALLOWED_CHAT_IDS") or _env_int_set("TELEGRAM_ALLOWED_CHAT_IDS"),
        telegram_owner_chat_id=next(iter(_env_int_set("GALLERY_TELEGRAM_OWNER_CHAT_ID") or _env_int_set("TELEGRAM_OWNER_CHAT_ID")), None),
        telegram_polling_enabled=_env_bool("GALLERY_TELEGRAM_POLLING_ENABLED", bool(_env("GALLERY_TELEGRAM_BOT_TOKEN") or _env("TELEGRAM_BOT_TOKEN"))),
        admin_discord_webhook_url=_env("GALLERY_ADMIN_DISCORD_WEBHOOK_URL"),
        digest_interval_hours=max(1, int(_env("GALLERY_DIGEST_INTERVAL_HOURS", "24"))),
    )
