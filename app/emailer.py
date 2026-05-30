import asyncio
import logging
import smtplib
import ssl
from email.message import EmailMessage

from .config import Settings


logger = logging.getLogger("image_gallery.email")


class EmailDeliveryError(RuntimeError):
    pass


def smtp_configured(settings: Settings) -> bool:
    return bool(settings.smtp_host and settings.smtp_from_email)


def send_email(settings: Settings, to_email: str, subject: str, body: str) -> None:
    if not smtp_configured(settings):
        raise EmailDeliveryError("SMTP is not configured. Set SMTP_HOST and SMTP_FROM_EMAIL.")

    message = EmailMessage()
    message["From"] = settings.smtp_from_email
    message["To"] = to_email
    message["Subject"] = subject
    message.set_content(body)

    context = ssl.create_default_context()
    try:
        if settings.smtp_port == 465:
            smtp_context = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=20, context=context)
        else:
            smtp_context = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=20)
        with smtp_context as smtp:
            smtp.ehlo()
            if settings.smtp_use_tls:
                smtp.starttls(context=context)
                smtp.ehlo()
            if settings.smtp_username:
                if not settings.smtp_password:
                    raise EmailDeliveryError("SMTP username is set but SMTP password is empty.")
                smtp.login(settings.smtp_username, settings.smtp_password)
            smtp.send_message(message)
    except EmailDeliveryError:
        raise
    except smtplib.SMTPAuthenticationError as exc:
        logger.exception("SMTP authentication failed while sending email to %s", to_email)
        raise EmailDeliveryError("SMTP authentication failed. Check the username and app-specific password.") from exc
    except smtplib.SMTPRecipientsRefused as exc:
        logger.exception("SMTP recipient was refused while sending email to %s", to_email)
        raise EmailDeliveryError("The mail server refused the recipient address.") from exc
    except smtplib.SMTPSenderRefused as exc:
        logger.exception("SMTP sender was refused while sending email to %s", to_email)
        raise EmailDeliveryError("The mail server refused SMTP_FROM_EMAIL. Use a sender address allowed by this account.") from exc
    except smtplib.SMTPException as exc:
        logger.exception("SMTP failed while sending email to %s", to_email)
        raise EmailDeliveryError(f"SMTP failed: {exc}") from exc
    except OSError as exc:
        logger.exception("Could not connect to SMTP while sending email to %s", to_email)
        raise EmailDeliveryError(f"Could not connect to SMTP server: {exc}") from exc


async def send_verification_email(settings: Settings, to_email: str, verify_url: str, code: str) -> None:
    await asyncio.to_thread(
        send_email,
        settings,
        to_email,
        "Verify your Image Gallery email",
        "Welcome to Image Gallery.\n\n"
        f"Your verification code is:\n\n{code}\n\n"
        "Enter this code in Image Gallery to verify your email address.\n\n"
        "You can also verify by opening the link below:\n\n"
        f"{verify_url}\n\n"
        "If you did not create this account, you can ignore this message.",
    )
