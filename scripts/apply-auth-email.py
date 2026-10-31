#!/usr/bin/env python3
"""Apply Grove's auth email identity to the linked Supabase project.

Two things live here, because Supabase couples them: on the free tier the
templates in `supabase/templates/` are rejected outright until a custom SMTP
provider is configured ("Email template modification is not available for free
tier projects using the default email provider"). So this script can set the
SMTP sender in the same run that installs the templates.

    # sender + templates, first time (prompts for the Google App Password)
    python3 scripts/apply-auth-email.py --gmail you@gmail.com

    # templates only, once SMTP is already set
    python3 scripts/apply-auth-email.py

    # any other provider
    SMTP_HOST=smtp-relay.brevo.com SMTP_PORT=587 SMTP_USER=… \
    SMTP_ADMIN_EMAIL=… python3 scripts/apply-auth-email.py

The password is prompted for (never echoed) unless SMTP_PASS is already in the
environment, so it stays out of shell history and out of the process list.

The target project comes from SUPABASE_PROJECT_REF, or else from the host of
SUPABASE_URL (`https://<project-ref>.supabase.co`). No project is hard-coded.

Deliberately *not* `supabase config push`: that would send the whole stock local
config.toml and disable the live Apple/Google identity providers.
"""

from __future__ import annotations

import base64
import getpass
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request



def resolve_project_ref() -> str:
    """SUPABASE_PROJECT_REF, else the subdomain of SUPABASE_URL."""
    explicit = os.environ.get("SUPABASE_PROJECT_REF", "").strip()
    if explicit:
        return explicit
    host = (urllib.parse.urlparse(os.environ.get("SUPABASE_URL", "").strip()).hostname or "").lower()
    if host.endswith(".supabase.co") and host.count(".") == 2:
        return host.split(".", 1)[0]
    raise SystemExit(
        "Set SUPABASE_PROJECT_REF, or SUPABASE_URL=https://<project-ref>.supabase.co, "
        "to name the Supabase project to configure."
    )


PROJECT_REF = resolve_project_ref()
TEMPLATES = pathlib.Path(__file__).resolve().parent.parent / "supabase" / "templates"

# The sender name is the whole point of the exercise: the "From" line reads
# "Grove", not "Supabase Auth".
SENDER_NAME = "Grove"
APPLE_BUNDLE_ID = "nz.co.thinkingai.Grove"
# This must mirror SessionService.isEmailSignInEnabled. Hiding a button is not
# an Auth boundary: the anon key ships in the app, so an attacker can call
# /auth/v1/otp directly. False still permits existing email identities to sign
# in with create_user=false while Apple and Google remain available for signup.
PUBLIC_EMAIL_SIGNUP_ENABLED = False

SUBJECTS = {
    "confirmation": "Your Grove sign-in code",
    "magic_link": "Your Grove sign-in code",
    "recovery": "Get back into Grove",
    "email_change": "Confirm your new Grove email address",
    "invite": "You've been invited to Grove",
    "reauthentication": "{{ .Token }} is your Grove verification code",
}


def management_token() -> str:
    """A CI token or the `supabase login` token from the macOS keychain."""
    raw = os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
    if not raw:
        try:
            raw = subprocess.check_output(
                ["security", "find-generic-password", "-s", "Supabase CLI", "-w"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (FileNotFoundError, subprocess.CalledProcessError) as error:
            raise SystemExit(
                "No Supabase management token. Set SUPABASE_ACCESS_TOKEN (CI) "
                "or run `supabase login` on this Mac."
            ) from error
    if raw.startswith("go-keyring-base64:"):
        raw = base64.b64decode(raw.removeprefix("go-keyring-base64:")).decode()
    return raw.strip()


def smtp_settings() -> dict[str, object]:
    """Read the sender from `--gmail <address>` or the SMTP_* environment."""
    args = sys.argv[1:]
    if args == ["--check"]:
        return {}
    if args and args[0] == "--gmail":
        if len(args) < 2 or "@" not in args[1]:
            raise SystemExit("usage: apply-auth-email.py --gmail you@gmail.com")
        host, port, user = "smtp.gmail.com", 465, args[1]
    elif args:
        raise SystemExit(f"unknown argument: {args[0]}")
    elif os.environ.get("SMTP_HOST"):
        host = os.environ["SMTP_HOST"]
        port = int(os.environ.get("SMTP_PORT", "465"))
        user = os.environ["SMTP_USER"]
    else:
        return {}

    password = os.environ.get("SMTP_PASS") or getpass.getpass(
        f"App password for {user} (not shown as you type/paste): "
    )
    # Google prints app passwords in four groups of four; the spaces are
    # presentation only and SMTP auth fails if they are sent.
    password = password.replace(" ", "").strip()
    if not password:
        raise SystemExit("no password entered — nothing changed")

    return {
        "smtp_host": host,
        # The management API expects the port as a string and 400s on a number.
        "smtp_port": str(port),
        "smtp_user": user,
        "smtp_pass": password,
        "smtp_admin_email": os.environ.get("SMTP_ADMIN_EMAIL") or user,
        "smtp_sender_name": SENDER_NAME,
        # The default provider's 2/hour cap is a testing limit; a real provider
        # can carry a normal sign-in rate.
        "rate_limit_email_sent": 60,
    }


def request(method: str, payload: dict[str, object] | None = None) -> dict[str, object]:
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{PROJECT_REF}/config/auth",
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
        headers={
            "Authorization": f"Bearer {management_token()}",
            "Content-Type": "application/json",
            # Without an explicit agent, Cloudflare answers urllib with a bare
            # "403 error code: 1010" that looks like an auth failure and isn't.
            "User-Agent": "grove-apply-auth-email/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        body = error.read().decode()
        print(f"HTTP {error.code}: {body}", file=sys.stderr)
        raise SystemExit(1) from error


def external_client_ids(body: dict[str, object], provider: str) -> set[str]:
    """Normalise the management API's primary + additional audience fields."""
    values: list[object] = [body.get(f"external_{provider}_client_id")]
    additional = body.get(f"external_{provider}_additional_client_ids")
    if isinstance(additional, list):
        values.extend(additional)
    elif additional:
        values.extend(str(additional).split(","))
    return {str(value).strip() for value in values if value and str(value).strip()}


def main() -> None:
    check_only = sys.argv[1:] == ["--check"]
    smtp = smtp_settings()
    if smtp:
        print(f"Setting SMTP sender: {SENDER_NAME} <{smtp['smtp_admin_email']}> via {smtp['smtp_host']}")
        request("PATCH", smtp)

    payload: dict[str, object] = {
        "external_email_enabled": PUBLIC_EMAIL_SIGNUP_ENABLED,
    }
    for name, subject in SUBJECTS.items():
        payload[f"mailer_subjects_{name}"] = subject
        payload[f"mailer_templates_{name}_content"] = (TEMPLATES / f"{name}.html").read_text()

    body = request("GET") if check_only else request("PATCH", payload)

    print(f"\nSender name : {body.get('smtp_sender_name') or '(none — still Supabase Auth)'}")
    print(f"SMTP host   : {body.get('smtp_host') or '(none — default Supabase provider)'}\n")
    failures: list[str] = []
    if not body.get("smtp_host"):
        failures.append("custom SMTP is not configured")

    code_templates = {"confirmation", "magic_link", "recovery", "email_change", "reauthentication"}
    for name in SUBJECTS:
        content = body.get(f"mailer_templates_{name}_content") or ""
        branded = ">Grove<" in content
        has_code = name not in code_templates or "{{ .Token }}" in content
        healthy = branded and has_code
        print(f"  {'ok ' if healthy else 'NOT'} {name:17} {body.get(f'mailer_subjects_{name}')!r}")
        if not branded:
            failures.append(f"{name} template is not Grove-branded")
        if not has_code:
            failures.append(f"{name} template does not include {{ .Token }}")

    if check_only:
        apple_ids = external_client_ids(body, "apple")
        google_ids = external_client_ids(body, "google")
        email_boundary_ready = (
            body.get("external_email_enabled") is PUBLIC_EMAIL_SIGNUP_ENABLED
        )
        apple_ready = body.get("external_apple_enabled") is True and APPLE_BUNDLE_ID in apple_ids
        google_ready = (
            body.get("external_google_enabled") is True
            and bool(google_ids)
            and body.get("external_google_skip_nonce_check") is True
        )
        print(
            f"\n  {'ok ' if email_boundary_ready else 'NOT'} Public email signup "
            f"{'enabled' if body.get('external_email_enabled') else 'disabled'}"
        )
        print(f"  {'ok ' if apple_ready else 'NOT'} Apple provider      {APPLE_BUNDLE_ID!r}")
        print(f"  {'ok ' if google_ready else 'NOT'} Google provider     native id-token grant")
        if not email_boundary_ready:
            failures.append(
                "public email signup is enabled while Grove hides it in the app"
            )
        if not apple_ready:
            failures.append(f"Apple provider is not enabled for {APPLE_BUNDLE_ID}")
        if not google_ready:
            failures.append("Google provider is not enabled for native iOS id-token grants")

        build_google_id = os.environ.get("GOOGLE_IOS_CLIENT_ID", "").strip()
        if build_google_id and build_google_id not in google_ids:
            failures.append("live Google audiences do not include GOOGLE_IOS_CLIENT_ID")

        build_supabase_url = os.environ.get("SUPABASE_URL", "").strip()
        if build_supabase_url:
            host = (urllib.parse.urlparse(build_supabase_url).hostname or "").lower()
            if host != f"{PROJECT_REF}.supabase.co":
                failures.append("SUPABASE_URL points at a different project than this live Auth preflight")

    if failures:
        print("\nAuth email configuration is not release-ready:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        raise SystemExit(1)

    if check_only:
        print("\n✓ Remote account providers and six-digit auth email configuration are ready.")
    else:
        print("\n✓ Remote auth email configuration is ready for six-digit codes.")


if __name__ == "__main__":
    main()
