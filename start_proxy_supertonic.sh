#!/usr/bin/env bash
# install-supertonic-openai-proxy.sh
#
# Minimaler OpenAI-kompatibler Proxy für einen bereits laufenden
# Supertonic-Server.
#
# Der Proxy:
#   - läuft mit Uvicorn auf 0.0.0.0:59113
#   - verändert den bestehenden Supertonic-Server auf 127.0.0.1:59112 NICHT
#   - splittet den Text NICHT
#   - gibt input vollständig und unverändert an Supertonic /v1/tts weiter
#   - übergibt voice, speed, language/lang, response_format und total_steps
#   - lässt Supertonic sein eigenes automatisches Text-Chunking erledigen
#
# Architektur:
#
#   Open WebUI
#      |
#      | POST /v1/audio/speech
#      v
#   Proxy auf :59113
#      |
#      | POST /v1/tts
#      v
#   vorhandener Supertonic-Server auf :59112
#
# Voraussetzungen:
#   - Python 3.10+
#   - python3-venv
#   - curl
#   - ein bereits laufender Supertonic-Server auf 127.0.0.1:59112
#
# Ausführen:
#   chmod +x install-supertonic-openai-proxy.sh
#   ./install-supertonic-openai-proxy.sh
#
# Im Hintergrund:
#   NOHUP=1 ./install-supertonic-openai-proxy.sh
#
# Optionale Werte beim Start:
#   DEFAULT_SPEED=1.5 \
#   DEFAULT_STEPS=10 \
#   NOHUP=1 \
#   ./install-supertonic-openai-proxy.sh
#
# Open WebUI:
#   Falls Open WebUI in Docker auf diesem Rechner läuft:
#     API Base URL: http://host.docker.internal:59113/v1
#
#   Falls Open WebUI direkt auf diesem Rechner läuft:
#     API Base URL: http://127.0.0.1:59113/v1
#
#   TTS Model: supertonic-3
#   TTS Voice: F1 oder M1
#   Geschwindigkeit: 0.7 bis 2.0
#
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Konfiguration
# =============================================================================

BASE_DIR="$(pwd -P)"

# Bestehender Supertonic-Server. Dieses Skript verändert ihn nicht.
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
BACKEND_PORT="${BACKEND_PORT:-59112}"

# Neuer Proxy.
PROXY_HOST="${PROXY_HOST:-0.0.0.0}"
PROXY_PORT="${PROXY_PORT:-59113}"

# Fallbacks, falls der Client / Open WebUI kein Feld mitsendet.
DEFAULT_SPEED="${DEFAULT_SPEED:-1.05}"
DEFAULT_STEPS="${DEFAULT_STEPS:-8}"
DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE:-de}"

MAX_INPUT_CHARS="${MAX_INPUT_CHARS:-12000}"
BACKEND_TIMEOUT_SECONDS="${BACKEND_TIMEOUT_SECONDS:-300}"

# Optionaler API-Key. Leer = keine Authentifizierung.
# Beispiel:
#   PROXY_API_KEY="mein-langer-geheimer-key" NOHUP=1 ./install-supertonic-openai-proxy.sh
PROXY_API_KEY="${PROXY_API_KEY:-}"

NOHUP_MODE="${NOHUP:-0}"

VENV_DIR="${BASE_DIR}/supertonic-proxy-venv"
APP_FILE="${BASE_DIR}/supertonic_proxy.py"
RUN_FILE="${BASE_DIR}/run-supertonic-proxy.sh"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/supertonic-proxy.log"
PID_FILE="${BASE_DIR}/supertonic-proxy.pid"
LOCK_DIR="${BASE_DIR}/.supertonic-proxy-install.lock"

# =============================================================================
# Hilfsfunktionen
# =============================================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
RESET=$'\033[0m'

info() {
  printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$*"
}

success() {
  printf '%s[OK]%s %s\n' "${GREEN}" "${RESET}" "$*"
}

warn() {
  printf '%s[WARNUNG]%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2
}

die() {
  printf '%s[FEHLER]%s %s\n' "${RED}" "${RESET}" "$*" >&2
  exit 1
}

cleanup() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

on_error() {
  local exit_code="$?"
  local line_number="$1"

  printf '%s[FEHLER]%s Skript-Abbruch in Zeile %s (Exit-Code %s).\n' \
    "${RED}" "${RESET}" "${line_number}" "${exit_code}" >&2

  if [[ -f "${LOG_FILE}" ]]; then
    printf 'Proxy-Log: %s\n' "${LOG_FILE}" >&2
  fi

  exit "${exit_code}"
}

trap cleanup EXIT
trap 'on_error $LINENO' ERR

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

find_python() {
  local candidate

  for candidate in python3.12 python3.11 python3.10 python3; do
    if command_exists "${candidate}"; then
      if "${candidate}" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
      then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done

  return 1
}

validate_port() {
  local value="$1"

  [[ "${value}" =~ ^[0-9]+$ ]] || die "Port '${value}' ist nicht numerisch."
  (( value >= 1 && value <= 65535 )) || die \
    "Port '${value}' muss zwischen 1 und 65535 liegen."
}

validate_float_range() {
  local value="$1"
  local minimum="$2"
  local maximum="$3"

  python3 - "${value}" "${minimum}" "${maximum}" <<'PY'
import sys

try:
    value = float(sys.argv[1])
    minimum = float(sys.argv[2])
    maximum = float(sys.argv[3])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if minimum <= value <= maximum else 1)
PY
}

validate_integer_range() {
  local value="$1"
  local minimum="$2"
  local maximum="$3"

  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  (( value >= minimum && value <= maximum ))
}

port_in_use() {
  local port="$1"

  if command_exists ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${port}$"
    return $?
  fi

  if command_exists lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  return 1
}

http_ready() {
  local url="$1"

  curl --fail --silent --show-error \
    --connect-timeout 3 \
    --max-time 10 \
    "${url}" >/dev/null 2>&1
}

wait_for_http() {
  local url="$1"
  local timeout_seconds="$2"
  local started
  local now

  started="$(date +%s)"

  while true; do
    if http_ready "${url}"; then
      return 0
    fi

    now="$(date +%s)"

    if (( now - started >= timeout_seconds )); then
      return 1
    fi

    sleep 1
  done
}

# =============================================================================
# Konfiguration prüfen
# =============================================================================

validate_port "${BACKEND_PORT}"
validate_port "${PROXY_PORT}"

if ! validate_float_range "${DEFAULT_SPEED}" "0.7" "2.0"; then
  die "DEFAULT_SPEED muss zwischen 0.7 und 2.0 liegen. Aktuell: ${DEFAULT_SPEED}"
fi

if ! validate_integer_range "${DEFAULT_STEPS}" "5" "12"; then
  die "DEFAULT_STEPS muss zwischen 5 und 12 liegen. Aktuell: ${DEFAULT_STEPS}"
fi

if ! validate_integer_range "${MAX_INPUT_CHARS}" "1" "1000000"; then
  die "MAX_INPUT_CHARS muss zwischen 1 und 1000000 liegen."
fi

if ! validate_float_range "${BACKEND_TIMEOUT_SECONDS}" "1" "3600"; then
  die "BACKEND_TIMEOUT_SECONDS muss zwischen 1 und 3600 liegen."
fi

[[ -n "${DEFAULT_LANGUAGE}" ]] || die \
  "DEFAULT_LANGUAGE darf nicht leer sein."

if [[ "${BACKEND_PORT}" == "${PROXY_PORT}" && "${BACKEND_HOST}" == "${PROXY_HOST}" ]]; then
  die "Backend und Proxy dürfen nicht denselben Host und Port verwenden."
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  die "Eine Installation läuft vermutlich bereits im Ordner: ${BASE_DIR}"
fi

PYTHON_BIN="$(find_python || true)"

[[ -n "${PYTHON_BIN}" ]] || die \
  "Python 3.10+ fehlt. Installiere z.B.: sudo apt update && sudo apt install -y python3 python3-venv python3-pip"

command_exists curl || die \
  "curl fehlt. Installiere z.B.: sudo apt install -y curl"

if ! "${PYTHON_BIN}" -m venv --help >/dev/null 2>&1; then
  die \
    "python3-venv fehlt. Installiere z.B.: sudo apt install -y python3-venv"
fi

mkdir -p "${LOG_DIR}"

# =============================================================================
# Bestehendes Supertonic-Backend prüfen — nur lesen, nichts ändern
# =============================================================================

info "Prüfe vorhandenen Supertonic-Server: http://${BACKEND_HOST}:${BACKEND_PORT}/docs"

if ! http_ready "http://${BACKEND_HOST}:${BACKEND_PORT}/docs"; then
  die \
    "Der bestehende Supertonic-Server ist nicht erreichbar. Dieses Skript verändert ihn nicht. Starte ihn zuerst auf ${BACKEND_HOST}:${BACKEND_PORT}."
fi

success "Vorhandener Supertonic-Server ist erreichbar."

# =============================================================================
# Proxy-Port prüfen
# =============================================================================

if port_in_use "${PROXY_PORT}"; then
  if http_ready "http://127.0.0.1:${PROXY_PORT}/health"; then
    warn "Port ${PROXY_PORT} wird bereits von einem erreichbaren Proxy verwendet."
    warn "Wenn das der bereits laufende Proxy ist, ist keine Neuinstallation nötig."
    exit 0
  fi

  die \
    "Port ${PROXY_PORT} ist bereits belegt. Prüfe mit: ss -ltnp | grep :${PROXY_PORT}"
fi

# =============================================================================
# venv und benötigte Python-Pakete einrichten
# =============================================================================

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  info "Erzeuge virtuelle Umgebung: ${VENV_DIR}"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
UVICORN_BIN="${VENV_DIR}/bin/uvicorn"

info "Aktualisiere pip, setuptools und wheel ..."
"${VENV_PYTHON}" -m pip install --upgrade \
  --disable-pip-version-check \
  pip \
  setuptools \
  wheel >/dev/null

info "Installiere FastAPI, Uvicorn, HTTPX und Pydantic ..."
"${VENV_PIP}" install --upgrade \
  --disable-pip-version-check \
  fastapi \
  "uvicorn[standard]" \
  httpx \
  pydantic >/dev/null

[[ -x "${UVICORN_BIN}" ]] || die \
  "Uvicorn wurde nicht korrekt installiert."

# =============================================================================
# Proxy-Datei erzeugen
# =============================================================================

info "Erzeuge Proxy-Datei: ${APP_FILE}"

cat > "${APP_FILE}" <<'PYTHON'
from __future__ import annotations

import hmac
import os
import time
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator


# ============================================================================
# Konfiguration
# ============================================================================

BACKEND_HOST = os.environ.get("SUPERTONIC_BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("SUPERTONIC_BACKEND_PORT", "59112"))
BACKEND_URL = f"http://{BACKEND_HOST}:{BACKEND_PORT}/v1/tts"

MIN_SPEED = 0.7
MAX_SPEED = 2.0
DEFAULT_SPEED = float(
    os.environ.get("SUPERTONIC_DEFAULT_SPEED", "1.05")
)

MIN_STEPS = 5
MAX_STEPS = 12
DEFAULT_STEPS = int(
    os.environ.get("SUPERTONIC_DEFAULT_STEPS", "8")
)

DEFAULT_LANGUAGE = os.environ.get(
    "SUPERTONIC_DEFAULT_LANGUAGE",
    "de",
).strip().lower()

MAX_INPUT_CHARS = int(
    os.environ.get("MAX_INPUT_CHARS", "12000")
)

TIMEOUT_SECONDS = float(
    os.environ.get("BACKEND_TIMEOUT_SECONDS", "300")
)

API_KEY = os.environ.get("PROXY_API_KEY", "").strip()

if not MIN_SPEED <= DEFAULT_SPEED <= MAX_SPEED:
    raise RuntimeError(
        f"SUPERTONIC_DEFAULT_SPEED must be between "
        f"{MIN_SPEED} and {MAX_SPEED}"
    )

if not MIN_STEPS <= DEFAULT_STEPS <= MAX_STEPS:
    raise RuntimeError(
        f"SUPERTONIC_DEFAULT_STEPS must be between "
        f"{MIN_STEPS} and {MAX_STEPS}"
    )

if not DEFAULT_LANGUAGE:
    raise RuntimeError(
        "SUPERTONIC_DEFAULT_LANGUAGE must not be empty"
    )


# ============================================================================
# HTTP-Client-Lebenszyklus
# ============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(
            TIMEOUT_SECONDS,
            connect=10.0,
        ),
        limits=httpx.Limits(
            max_connections=16,
            max_keepalive_connections=8,
        ),
        follow_redirects=False,
    )

    try:
        yield
    finally:
        await app.state.http_client.aclose()


app = FastAPI(
    title="Supertonic OpenAI Proxy",
    version="1.0.0",
    lifespan=lifespan,
)


# ============================================================================
# OpenAI-kompatibler Request
# ============================================================================

class SpeechRequest(BaseModel):
    """
    OpenAI-ähnliches Schema.

    Der Proxy akzeptiert zusätzliche Felder von Clients, nutzt aber nur Werte,
    die an die native Supertonic-API abgebildet werden können.
    """

    model_config = ConfigDict(extra="allow")

    model: str = Field(
        default="supertonic-3",
        min_length=1,
        max_length=256,
    )

    input: str = Field(
        ...,
        min_length=1,
        max_length=MAX_INPUT_CHARS,
    )

    # Die Stimme wird exakt weitergereicht.
    # F1 ist nur ein Fallback, wenn kein voice-Feld gesendet wird.
    voice: str | None = None

    # Wird an Supertonic weitergegeben, aber auf 0.7 bis 2.0 begrenzt.
    speed: float | None = None

    response_format: str = "wav"

    # Beide Varianten werden akzeptiert.
    lang: str | None = None
    language: str | None = None

    # Supertonic-native Qualitätsparameter.
    total_steps: int | None = None
    steps: int | None = None

    @field_validator("input")
    @classmethod
    def validate_input(cls, value: str) -> str:
        value = value.strip()

        if not value:
            raise ValueError("input darf nicht leer sein")

        return value

    @field_validator("voice")
    @classmethod
    def normalize_voice(
        cls,
        value: str | None,
    ) -> str | None:
        if value is None:
            return None

        value = value.strip()
        return value or None


# ============================================================================
# Parameterumsetzung
# ============================================================================

def resolve_speed(
    value: float | None,
) -> tuple[float, float, bool]:
    """
    Rückgabe:
      requested_speed: Clientwert oder Default
      applied_speed: auf 0.7 bis 2.0 begrenzt
      clamped: ob begrenzt wurde
    """

    requested_speed = (
        DEFAULT_SPEED
        if value is None
        else float(value)
    )

    applied_speed = max(
        MIN_SPEED,
        min(MAX_SPEED, requested_speed),
    )

    return (
        requested_speed,
        applied_speed,
        applied_speed != requested_speed,
    )


def resolve_language(
    request: SpeechRequest,
) -> str:
    """
    Normalisiert de-DE/de_DE zu de.
    """

    language = (
        request.language
        or request.lang
        or DEFAULT_LANGUAGE
    ).strip().lower()

    language = language.replace("_", "-")
    language = language.split("-", 1)[0]

    return language or DEFAULT_LANGUAGE


def resolve_steps(
    request: SpeechRequest,
) -> int:
    """
    Priorität:
      1. total_steps im Request
      2. steps im Request
      3. Default aus SUPERTONIC_DEFAULT_STEPS
    """

    steps = request.total_steps

    if steps is None:
        steps = request.steps

    if steps is None:
        steps = DEFAULT_STEPS

    return max(
        MIN_STEPS,
        min(MAX_STEPS, int(steps)),
    )


def resolve_format(
    request: SpeechRequest,
) -> str:
    """
    Akzeptiert nur Audioformate, die der Proxy sinnvoll weiterreichen kann.
    """

    response_format = request.response_format.strip().lower()

    allowed = {
        "wav",
        "mp3",
        "flac",
        "ogg",
        "opus",
        "pcm",
    }

    if response_format not in allowed:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Nicht unterstütztes response_format: "
                f"{response_format}. Erlaubt: "
                f"{', '.join(sorted(allowed))}"
            ),
        )

    return response_format


def content_type_for_format(
    response_format: str,
) -> str:
    return {
        "wav": "audio/wav",
        "mp3": "audio/mpeg",
        "flac": "audio/flac",
        "ogg": "audio/ogg",
        "opus": "audio/ogg; codecs=opus",
        "pcm": "audio/L16",
    }.get(
        response_format,
        "application/octet-stream",
    )


# ============================================================================
# Optionaler API-Key-Schutz
# ============================================================================

def has_valid_api_key(
    request: Request,
) -> bool:
    """
    Wenn PROXY_API_KEY leer ist, ist der Proxy offen.

    Andernfalls akzeptiert er:
      Authorization: Bearer <PROXY_API_KEY>
    oder:
      X-API-Key: <PROXY_API_KEY>
    """

    if not API_KEY:
        return True

    authorization = request.headers.get(
        "authorization",
        "",
    )

    x_api_key = request.headers.get(
        "x-api-key",
        "",
    )

    if authorization.startswith("Bearer "):
        supplied_key = authorization.removeprefix(
            "Bearer "
        ).strip()

        if hmac.compare_digest(
            supplied_key,
            API_KEY,
        ):
            return True

    if x_api_key and hmac.compare_digest(
        x_api_key,
        API_KEY,
    ):
        return True

    return False


# ============================================================================
# Authentifizierung
# ============================================================================

@app.middleware("http")
async def api_key_middleware(
    request: Request,
    call_next: Any,
) -> Response:
    """
    /health und /docs bleiben ohne Key erreichbar, damit Monitoring funktioniert.
    """

    public_paths = {
        "/",
        "/health",
        "/docs",
        "/openapi.json",
    }

    if (
        request.url.path not in public_paths
        and not has_valid_api_key(request)
    ):
        return JSONResponse(
            status_code=401,
            content={
                "error": {
                    "message": "Invalid or missing API key.",
                    "type": "authentication_error",
                }
            },
        )

    response = await call_next(request)

    response.headers[
        "X-Content-Type-Options"
    ] = "nosniff"

    return response


# ============================================================================
# Fehlerformatierung
# ============================================================================

@app.exception_handler(RequestValidationError)
async def validation_error(
    request: Request,
    exc: RequestValidationError,
) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={
            "error": {
                "message": "Ungültiger Request.",
                "type": "invalid_request_error",
                "details": exc.errors(),
            }
        },
    )


@app.exception_handler(HTTPException)
async def http_error(
    request: Request,
    exc: HTTPException,
) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "message": str(exc.detail),
                "type": "api_error",
            }
        },
    )


@app.exception_handler(Exception)
async def unknown_error(
    request: Request,
    exc: Exception,
) -> JSONResponse:
    return JSONResponse(
        status_code=500,
        content={
            "error": {
                "message": "Interner Proxy-Fehler.",
                "type": "internal_server_error",
            }
        },
    )


# ============================================================================
# Health und Modelle
# ============================================================================

@app.get("/")
async def root() -> dict[str, Any]:
    return {
        "service": "supertonic-openai-proxy",
        "status": "ok",
        "backend": BACKEND_URL,
    }


@app.get("/health")
async def health(
    request: Request,
) -> JSONResponse:
    """
    Prüft nur die Erreichbarkeit des bereits vorhandenen Backends.
    Es ändert am Backend nichts.
    """

    try:
        backend_response = await request.app.state.http_client.get(
            f"http://{BACKEND_HOST}:{BACKEND_PORT}/docs",
            timeout=5.0,
        )
    except httpx.HTTPError as exc:
        return JSONResponse(
            status_code=503,
            content={
                "status": "degraded",
                "backend": BACKEND_URL,
                "error": str(exc),
            },
        )

    if backend_response.status_code >= 500:
        return JSONResponse(
            status_code=503,
            content={
                "status": "degraded",
                "backend": BACKEND_URL,
                "backend_http_status": backend_response.status_code,
            },
        )

    return JSONResponse(
        status_code=200,
        content={
            "status": "ok",
            "backend": BACKEND_URL,
            "speed_range": [MIN_SPEED, MAX_SPEED],
            "default_speed": DEFAULT_SPEED,
            "default_steps": DEFAULT_STEPS,
        },
    )


@app.get("/v1/models")
async def models() -> dict[str, Any]:
    return {
        "object": "list",
        "data": [
            {
                "id": "supertonic-3",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "local-supertonic",
            }
        ],
    }


# ============================================================================
# OpenAI-kompatibler TTS-Endpoint
# ============================================================================

@app.post("/v1/audio/speech")
async def audio_speech(
    speech: SpeechRequest,
    request: Request,
) -> Response:
    """
    Reicht einen einzigen, vollständigen und unveränderten Text an Supertonic.

    WICHTIG:
      - Der Proxy führt KEIN Text-Chunking aus.
      - Der Proxy verändert speech.input nicht.
      - Supertonic selbst übernimmt bei langen Texten sein eigenes Chunking.
      - voice wird nicht auf F1 überschrieben. F1 ist nur Fallback ohne voice.
    """

    requested_speed, applied_speed, speed_clamped = resolve_speed(
        speech.speed,
    )

    language = resolve_language(
        speech,
    )

    total_steps = resolve_steps(
        speech,
    )

    response_format = resolve_format(
        speech,
    )

    voice = (speech.voice or "F1").strip() or "F1"

    # Der vollständige Text geht unverändert an den nativen Supertonic-Server.
    native_payload = {
        "text": speech.input,
        "voice": voice,
        "lang": language,
        "speed": applied_speed,
        "total_steps": total_steps,
        "response_format": response_format,
    }

    try:
        backend_response = await request.app.state.http_client.post(
            BACKEND_URL,
            json=native_payload,
            headers={
                "Accept": "audio/*",
            },
        )

    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="Supertonic-Backend hat das Zeitlimit überschritten.",
        ) from exc

    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=502,
            detail=(
                "Supertonic-Backend ist nicht erreichbar: "
                f"{exc}"
            ),
        ) from exc

    if backend_response.status_code >= 400:
        backend_message = backend_response.text[:4000]

        raise HTTPException(
            status_code=502,
            detail=(
                "Supertonic-Backend antwortete mit HTTP "
                f"{backend_response.status_code}: "
                f"{backend_message}"
            ),
        )

    audio_bytes = backend_response.content

    if not audio_bytes:
        raise HTTPException(
            status_code=502,
            detail="Supertonic-Backend lieferte keine Audiodaten.",
        )

    response_headers = {
        "Content-Disposition": (
            f'attachment; filename="speech.{response_format}"'
        ),
        "X-Supertonic-Model-Requested": speech.model,
        "X-Supertonic-Voice": voice,
        "X-Supertonic-Language": language,
        "X-Supertonic-Requested-Speed": str(
            requested_speed,
        ),
        "X-Supertonic-Applied-Speed": str(
            applied_speed,
        ),
        "X-Supertonic-Speed-Clamped": str(
            speed_clamped,
        ).lower(),
        "X-Supertonic-Total-Steps": str(
            total_steps,
        ),
        "X-Proxy-Text-Chunking": "disabled",
    }

    for header_name in (
        "x-sample-rate",
        "x-audio-duration",
        "x-supertonic-version",
    ):
        if header_name in backend_response.headers:
            response_headers[header_name] = (
                backend_response.headers[header_name]
            )

    return Response(
        content=audio_bytes,
        media_type=backend_response.headers.get(
            "content-type",
            content_type_for_format(response_format),
        ),
        headers=response_headers,
    )
PYTHON

chmod 0640 "${APP_FILE}"

# =============================================================================
# Startskript erzeugen
# =============================================================================

info "Erzeuge Startskript: ${RUN_FILE}"

cat > "${RUN_FILE}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

export SUPERTONIC_BACKEND_HOST="${BACKEND_HOST}"
export SUPERTONIC_BACKEND_PORT="${BACKEND_PORT}"

export SUPERTONIC_DEFAULT_SPEED="${DEFAULT_SPEED}"
export SUPERTONIC_DEFAULT_STEPS="${DEFAULT_STEPS}"
export SUPERTONIC_DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE}"

export MAX_INPUT_CHARS="${MAX_INPUT_CHARS}"
export BACKEND_TIMEOUT_SECONDS="${BACKEND_TIMEOUT_SECONDS}"

export PROXY_API_KEY="${PROXY_API_KEY}"

exec "${UVICORN_BIN}" supertonic_proxy:app \\
  --app-dir "${BASE_DIR}" \\
  --host "${PROXY_HOST}" \\
  --port "${PROXY_PORT}"
EOF

chmod 0750 "${RUN_FILE}"

# =============================================================================
# Python-Syntax prüfen
# =============================================================================

info "Prüfe Python-Syntax des Proxys ..."
"${VENV_PYTHON}" -m py_compile "${APP_FILE}"
success "Python-Syntax ist gültig."

# =============================================================================
# Proxy starten
# =============================================================================

if [[ "${NOHUP_MODE}" == "1" ]]; then
  info "Starte Proxy im Hintergrund ..."
  info "Logdatei: ${LOG_FILE}"

  (
    umask 077
    exec nohup "${RUN_FILE}" >>"${LOG_FILE}" 2>&1
  ) &

  PROXY_PID="$!"
  printf '%s\n' "${PROXY_PID}" > "${PID_FILE}"

  info "Warte auf Healthcheck ..."

  if ! wait_for_http "http://127.0.0.1:${PROXY_PORT}/health" 30; then
    if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
      warn "Der Proxy-Prozess wurde beendet. Letzte Logzeilen:"
      tail -n 100 "${LOG_FILE}" 2>/dev/null || true
      die "Proxy konnte nicht gestartet werden."
    fi

    warn "Der Prozess läuft, aber der Healthcheck antwortet noch nicht."
    warn "Prüfe: tail -f '${LOG_FILE}'"
  else
    success "Proxy läuft auf Port ${PROXY_PORT}; PID: ${PROXY_PID}"
  fi

  cat <<EOF

FERTIG.

Open WebUI-Einstellungen:

  TTS Engine:
  OpenAI

  API Base URL, falls Open WebUI in Docker auf diesem Host läuft:
  http://host.docker.internal:${PROXY_PORT}/v1

  API Base URL, falls Open WebUI direkt auf diesem Host läuft:
  http://127.0.0.1:${PROXY_PORT}/v1

  TTS Model:
  supertonic-3

  TTS Voice:
  F1 oder M1

  Geschwindigkeit:
  0.7 bis 2.0

Status prüfen:
  curl -fsS http://127.0.0.1:${PROXY_PORT}/health

Logs:
  tail -f "${LOG_FILE}"

Stoppen:
  kill \$(cat "${PID_FILE}")

EOF

  exit 0
fi

cat <<EOF

Installation abgeschlossen.

Der Proxy startet jetzt im Vordergrund auf:
  http://${PROXY_HOST}:${PROXY_PORT}

Open WebUI in Docker:
  http://host.docker.internal:${PROXY_PORT}/v1

Open WebUI direkt auf diesem Host:
  http://127.0.0.1:${PROXY_PORT}/v1

Mit Ctrl+C beendest du den Proxy.

EOF

exec "${RUN_FILE}"
