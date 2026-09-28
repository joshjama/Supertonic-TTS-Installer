#!/usr/bin/env bash
# Proxy für Supertonic /v1/tts. Ändert den Originalserver nicht.
set -Eeuo pipefail
BASE_DIR="$(pwd -P)"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
BACKEND_PORT="${BACKEND_PORT:-59112}"
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-59113}"
DEFAULT_SPEED="${DEFAULT_SPEED:-1.05}"
DEFAULT_STEPS="${DEFAULT_STEPS:-8}"
DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE:-de}"
MAX_INPUT_CHARS="${MAX_INPUT_CHARS:-12000}"
BACKEND_TIMEOUT_SECONDS="${BACKEND_TIMEOUT_SECONDS:-300}"
PROXY_API_KEY="${PROXY_API_KEY:-}"
NOHUP="${NOHUP:-0}"
VENV_DIR="$BASE_DIR/supertonic-proxy-venv"
APP_FILE="$BASE_DIR/supertonic_proxy.py"
RUN_FILE="$BASE_DIR/run-supertonic-proxy.sh"
LOG_FILE="$BASE_DIR/logs/supertonic-proxy.log"
PID_FILE="$BASE_DIR/supertonic-proxy.pid"
command -v python3 >/dev/null || { echo 'Python fehlt' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl fehlt' >&2; exit 1; }
python3 - "$DEFAULT_SPEED" "$DEFAULT_STEPS" "$MAX_INPUT_CHARS" "$BACKEND_TIMEOUT_SECONDS" "$BACKEND_PORT" "$PROXY_PORT" <<'PY'
import math, sys
speed, steps, length, timeout, backend, proxy = sys.argv[1:]
assert math.isfinite(float(speed)) and .7 <= float(speed) <= 2
assert 5 <= int(steps) <= 12
assert 1 <= int(length) <= 1000000
assert math.isfinite(float(timeout)) and 1 <= float(timeout) <= 3600
assert 1 <= int(backend) <= 65535 and 1 <= int(proxy) <= 65535
assert backend != proxy
PY
curl -fsS --connect-timeout 3 --max-time 10 "http://${BACKEND_HOST}:${BACKEND_PORT}/docs" >/dev/null || { echo 'Supertonic nicht erreichbar' >&2; exit 1; }
# Nicht stillschweigend eine bereits laufende alte Proxy-Version stehen lassen.
if python3 - "$PROXY_PORT" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.settimeout(2)
    s.connect(('127.0.0.1', int(sys.argv[1])))
except OSError:
    sys.exit(1)
else:
    sys.exit(0)
finally:
    s.close()
PY
then
  echo "Port $PROXY_PORT belegt. Alten Proxy zuerst stoppen (ggf. sudo systemctl stop supertonic-proxy.service)." >&2
  exit 1
fi
if [[ ! -x "$VENV_DIR/bin/python" ]]; then python3 -m venv "$VENV_DIR"; fi
"$VENV_DIR/bin/python" -m pip install --disable-pip-version-check 'fastapi>=0.100' 'uvicorn[standard]' httpx 'pydantic>=2'
mkdir -p "$BASE_DIR/logs"
cat > "$APP_FILE" <<'PYTHON'
from __future__ import annotations
import hmac
import math
import os
import time
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

HOST = os.getenv('SUPERTONIC_BACKEND_HOST', '127.0.0.1')
PORT = int(os.getenv('SUPERTONIC_BACKEND_PORT', '59112'))
URL = f'http://{HOST}:{PORT}/v1/tts'
DEFAULT_SPEED = float(os.getenv('SUPERTONIC_DEFAULT_SPEED', '1.05'))
DEFAULT_STEPS = int(os.getenv('SUPERTONIC_DEFAULT_STEPS', '8'))
DEFAULT_LANGUAGE = os.getenv('SUPERTONIC_DEFAULT_LANGUAGE', 'de')
MAX_CHARS = int(os.getenv('MAX_INPUT_CHARS', '12000'))
TIMEOUT = float(os.getenv('BACKEND_TIMEOUT_SECONDS', '300'))
KEY = os.getenv('PROXY_API_KEY', '')
FORMATS = {'wav': 'audio/wav', 'flac': 'audio/flac', 'ogg': 'audio/ogg'}
QUOTE_REPLACEMENTS = str.maketrans({
    '„': '"', '“': '"', '”': '"', '«': '"', '»': '"',
    '‚': "'", '‘': "'", '’': "'", '‹': "'", '›': "'",
})

@asynccontextmanager
async def lifespan(app: FastAPI):
    async with httpx.AsyncClient(timeout=httpx.Timeout(TIMEOUT, connect=10.0),
                                 limits=httpx.Limits(max_connections=16, max_keepalive_connections=8),
                                 follow_redirects=False) as client:
        app.state.client = client
        yield

app = FastAPI(title='Supertonic OpenAI TTS Proxy', lifespan=lifespan)

class Speech(BaseModel):
    model_config = ConfigDict(extra='allow')
    model: str = 'supertonic-3'
    input: str = Field(min_length=1, max_length=MAX_CHARS)
    voice: str | None = None
    speed: float | None = None
    language: str | None = None
    lang: str | None = None
    total_steps: int | None = None
    steps: int | None = None
    response_format: str = 'wav'

@app.middleware('http')
async def auth(request: Request, call_next: Any):
    if KEY and request.url.path not in ('/', '/health', '/docs', '/openapi.json'):
        auth_header = request.headers.get('authorization', '')
        bearer = auth_header[7:].strip() if auth_header.lower().startswith('bearer ') else ''
        api_key = request.headers.get('x-api-key', '')
        if not (hmac.compare_digest(bearer, KEY) or hmac.compare_digest(api_key, KEY)):
            return JSONResponse(status_code=401, content={'error': {'message': 'Invalid API key'}})
    response = await call_next(request)
    response.headers['X-Content-Type-Options'] = 'nosniff'
    return response

@app.get('/health')
async def health(request: Request):
    try:
        r = await request.app.state.client.get(f'http://{HOST}:{PORT}/docs', timeout=5)
        if r.status_code >= 400:
            raise RuntimeError(f'Backend HTTP {r.status_code}')
        return {'status': 'ok', 'backend': URL}
    except (httpx.HTTPError, RuntimeError) as exc:
        return JSONResponse(status_code=503, content={'status': 'degraded', 'error': str(exc)})

@app.get('/v1/models')
async def models():
    return {'object': 'list', 'data': [{'id': 'supertonic-3', 'object': 'model',
                                      'created': int(time.time()), 'owned_by': 'local-supertonic'}]}

@app.post('/v1/audio/speech')
async def speech_endpoint(speech: Speech, request: Request):
    # Open WebUI schickt je Textabschnitt einen separaten HTTP-Request.
    # Pro Request muss GENAU EINE vollständige, abspielbare Audiodatei zurückkommen.
    text = speech.input.translate(QUOTE_REPLACEMENTS)
    if not text.strip():
        raise HTTPException(status_code=422, detail='Leerer Text')
    requested = DEFAULT_SPEED if speech.speed is None else speech.speed
    if not math.isfinite(requested):
        raise HTTPException(status_code=422, detail='speed muss endlich sein')
    speed = min(2.0, max(0.7, requested))
    steps = speech.total_steps if speech.total_steps is not None else speech.steps
    steps = DEFAULT_STEPS if steps is None else min(12, max(5, steps))
    language = (speech.language or speech.lang or DEFAULT_LANGUAGE).strip().lower().replace('_', '-').split('-', 1)[0]
    if not language:
        language = DEFAULT_LANGUAGE
    voice = (speech.voice or 'F1').strip() or 'F1'
    fmt = speech.response_format.lower().strip()
    if fmt not in FORMATS:
        raise HTTPException(status_code=400, detail='Nur wav, flac und ogg werden vom nativen Backend unterstützt')
    payload = {'text': text, 'voice': voice, 'lang': language, 'speed': speed,
               'steps': steps, 'response_format': fmt}
    try:
        r = await request.app.state.client.post(URL, json=payload)
    except httpx.TimeoutException as exc:
        raise HTTPException(status_code=504, detail='Supertonic-Timeout') from exc
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f'Supertonic nicht erreichbar: {exc}') from exc
    if r.status_code >= 400:
        raise HTTPException(status_code=502, detail=f'Supertonic HTTP {r.status_code}: {r.text[:1000]}')
    audio = r.content
    if not audio:
        raise HTTPException(status_code=502, detail='Supertonic lieferte leeres Audio')
    if fmt == 'wav' and not (audio[:4] == b'RIFF' and audio[8:12] == b'WAVE'):
        raise HTTPException(status_code=502, detail='Supertonic lieferte kein gültiges WAV-Containerformat')
    headers = {'X-Supertonic-Applied-Speed': str(speed), 'X-Supertonic-Voice': voice,
               'X-Supertonic-Total-Steps': str(steps), 'X-Proxy-Input-Chars': str(len(text))}
    for name in ('x-audio-duration', 'x-sample-rate', 'x-supertonic-version'):
        if name in r.headers:
            headers[name] = r.headers[name]
    return Response(content=audio, media_type=FORMATS[fmt], headers=headers)
PYTHON
chmod 0640 "$APP_FILE"
# Keine Shell-Interpolation von API-Key, Pfaden oder Sonderzeichen im generierten Skript.
cat > "$RUN_FILE" <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
set -a
source "$DIR/.supertonic-proxy.env"
set +a
exec "$DIR/supertonic-proxy-venv/bin/uvicorn" supertonic_proxy:app --app-dir "$DIR" --host "$PROXY_HOST" --port "$PROXY_PORT"
RUN
chmod 0750 "$RUN_FILE"
# Environment-Werte ohne unsichere Shell-Escapes serialisieren.
python3 - "$BASE_DIR/.supertonic-proxy.env" "$BACKEND_HOST" "$BACKEND_PORT" "$PROXY_HOST" "$PROXY_PORT" "$DEFAULT_SPEED" "$DEFAULT_STEPS" "$DEFAULT_LANGUAGE" "$MAX_INPUT_CHARS" "$BACKEND_TIMEOUT_SECONDS" "$PROXY_API_KEY" <<'PY'
import shlex, sys
path = sys.argv[1]
names = ('SUPERTONIC_BACKEND_HOST', 'SUPERTONIC_BACKEND_PORT', 'PROXY_HOST', 'PROXY_PORT', 'SUPERTONIC_DEFAULT_SPEED', 'SUPERTONIC_DEFAULT_STEPS', 'SUPERTONIC_DEFAULT_LANGUAGE', 'MAX_INPUT_CHARS', 'BACKEND_TIMEOUT_SECONDS', 'PROXY_API_KEY')
with open(path, 'w') as f:
    for name, value in zip(names, sys.argv[2:]):
        f.write(f'{name}={shlex.quote(value)}\n')
PY
chmod 0600 "$BASE_DIR/.supertonic-proxy.env"
"$VENV_DIR/bin/python" -m py_compile "$APP_FILE"
if [[ "$NOHUP" == '1' ]]; then
  nohup "$RUN_FILE" >>"$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
  for i in {1..30}; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${PROXY_PORT}/health" >/dev/null 2>&1; then
      echo "Proxy bereit. PID: $(cat "$PID_FILE"); Log: $LOG_FILE"
      exit 0
    fi
    sleep 1
  done
  tail -n 30 "$LOG_FILE" >&2 || true
  echo 'Proxy nicht bereit' >&2
  exit 1
fi
exec "$RUN_FILE"
