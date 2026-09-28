#!/usr/bin/env bash
#
# install-and-run-supertonic.sh
#
# Installiert Supertonic 3 in ./supertonic-venv (relativ zum aktuellen Ordner)
# und startet den offiziellen HTTP-Server auf:
#
#   http://127.0.0.1:59112
#   OpenAI-kompatibles TTS: POST /v1/audio/speech
#   Native Supertonic-API:  POST /v1/tts
#   API-Dokumentation:       GET  /docs
#
# Anforderungen:
#   - Linux Mint / Debian / Ubuntu
#   - Python 3.10 oder neuer
#   - Internetzugriff beim ersten Start (Paket + Modell-Download)
#
# Hinweis zur Sicherheit:
#   Der Server bindet absichtlich an 127.0.0.1, wie angefordert. Er besitzt
#   keine eingebaute API-Key-Absicherung. Exponiere Port 59112 nicht direkt
#   ins Internet. Nutze für Internet-Zugriff Caddy/Nginx/Traefik mit HTTPS,
#   Authentifizierung und Firewall-Regeln.
#
# Nutzung:
#   chmod +x install-and-run-supertonic.sh
#   ./install-and-run-supertonic.sh
#
# Optional:
#   PORT=59112 HOST=127.0.0.1 ./install-and-run-supertonic.sh
#   NOHUP=1 ./install-and-run-supertonic.sh
#
set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Konfiguration
###############################################################################
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-59112}"

# Alles relativ zu dem Ordner, aus dem das Skript ausgeführt wird:
BASE_DIR="$(pwd -P)"
VENV_DIR="${BASE_DIR}/supertonic-venv"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/supertonic-${PORT}.log"
PID_FILE="${BASE_DIR}/supertonic-${PORT}.pid"
LOCK_DIR="${BASE_DIR}/.supertonic-install.lock"

# NOHUP=1 startet den Dienst im Hintergrund und schreibt Logs in LOG_FILE.
# Standardmäßig bleibt der Server im Vordergrund, damit man Startfehler direkt
# im Terminal sieht und ihn mit Ctrl+C sauber stoppen kann.
NOHUP_MODE="${NOHUP:-0}"

# 0 = nur prüfen/warnen; 1 = bei fehlendem Healthcheck mit Fehler beenden.
STRICT_HEALTHCHECK="${STRICT_HEALTHCHECK:-0}"

###############################################################################
# Hilfsfunktionen
###############################################################################
COLOR_RED=$'\033[0;31m'
COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_BLUE=$'\033[0;34m'
COLOR_RESET=$'\033[0m'

info() {
  printf '%s[INFO]%s %s\n' "${COLOR_BLUE}" "${COLOR_RESET}" "$*"
}

success() {
  printf '%s[OK]%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

warn() {
  printf '%s[WARNUNG]%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*" >&2
}

die() {
  printf '%s[FEHLER]%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no=$1
  printf '\n%s[FEHLER]%s Das Skript ist in Zeile %s mit Exit-Code %s abgebrochen.\n' \
    "${COLOR_RED}" "${COLOR_RESET}" "${line_no}" "${exit_code}" >&2
  printf 'Wenn eine Logdatei existiert, prüfe: %s\n' "${LOG_FILE}" >&2
  exit "${exit_code}"
}

trap 'on_error $LINENO' ERR

cleanup_lock() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

trap cleanup_lock EXIT

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_integer_port() {
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "PORT muss numerisch sein, erhalten: '${PORT}'."
  (( PORT >= 1 && PORT <= 65535 )) || die "PORT muss zwischen 1 und 65535 liegen."
}

require_valid_host() {
  case "${HOST}" in
    127.0.0.1|127.0.0.1|localhost|::|::1)
      return 0
      ;;
    *)
      # Kein vollständiger Security-Validator; verhindert aber leere und
      # offensichtliche problematische Eingaben in der Kommandozeile.
      [[ -n "${HOST}" ]] || die "HOST darf nicht leer sein."
      ;;
  esac
}

is_port_in_use() {
  local port="$1"

  if command_exists ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${port}$"
    return $?
  fi

  if command_exists lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  return 1
}

find_python() {
  local candidate
  for candidate in python3.12 python3.11 python3.10 python3; do
    if command_exists "${candidate}"; then
      local major minor
      major="$("${candidate}" -c 'import sys; print(sys.version_info.major)' 2>/dev/null || true)"
      minor="$("${candidate}" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || true)"
      if [[ "${major}" == "3" ]] && [[ "${minor}" =~ ^[0-9]+$ ]] && (( minor >= 10 )); then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

wait_for_http() {
  local url="$1"
  local seconds="$2"
  local started now elapsed

  started="$(date +%s)"

  while true; do
    if curl --fail --silent --show-error \
      --connect-timeout 2 \
      --max-time 5 \
      "${url}" >/dev/null 2>&1; then
      return 0
    fi

    now="$(date +%s)"
    elapsed=$(( now - started ))

    if (( elapsed >= seconds )); then
      return 1
    fi

    sleep 1
  done
}

server_is_healthy() {
  # /docs ist unabhängig von einer Modell-Synthese und beantwortet zuverlässig,
  # sobald Uvicorn/FastAPI hochgefahren ist.
  wait_for_http "http://127.0.0.1:${PORT}/docs" 3
}

stop_pid_if_running() {
  if [[ ! -f "${PID_FILE}" ]]; then
    return 0
  fi

  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"

  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    info "Ein von diesem Setup gestarteter Prozess läuft bereits (PID ${pid})."
    return 0
  fi

  rm  "${PID_FILE}"
}

###############################################################################
# Vorbedingungen
###############################################################################
require_integer_port
require_valid_host

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  die "Eine Installation/Startinstanz läuft vermutlich bereits in diesem Ordner: ${BASE_DIR}"
fi

info "Arbeitsordner: ${BASE_DIR}"
info "Zieladresse: http://${HOST}:${PORT}"
info "Virtuelle Umgebung: ${VENV_DIR}"

if [[ "${HOST}" == "127.0.0.1" || "${HOST}" == "::" ]]; then
  warn "Der Dienst wird auf allen Netzwerkinterfaces veröffentlicht."
  warn "Der offizielle Supertonic-Server hat keine eingebaute API-Key-Authentifizierung."
  warn "Für Internetzugriff: Firewall + Reverse Proxy mit TLS und Authentifizierung verwenden."
fi

PYTHON_BIN="$(find_python || true)"
[[ -n "${PYTHON_BIN}" ]] || die \
  "Python 3.10+ wurde nicht gefunden. Installiere z.B.: sudo apt install python3 python3-venv python3-pip"

success "Geeignete Python-Version gefunden: $(${PYTHON_BIN} --version)"

if ! "${PYTHON_BIN}" -m venv --help >/dev/null 2>&1; then
  die "Das Python-Modul 'venv' fehlt. Installiere es z.B. mit: sudo apt install python3-venv"
fi

if ! command_exists curl; then
  die "curl fehlt. Installiere es z.B. mit: sudo apt install curl"
fi

mkdir -p "${LOG_DIR}"

if is_port_in_use "${PORT}"; then
  if server_is_healthy; then
    warn "Port ${PORT} wird bereits von einem erreichbaren HTTP-Dienst verwendet."
    warn "Wenn das dein vorhandener Supertonic-Server ist, ist kein Neustart nötig:"
    printf '      http://127.0.0.1:%s/v1/audio/speech\n' "${PORT}"
    exit 0
  fi

  die "Port ${PORT} ist bereits belegt. Prüfe den Prozess mit: ss -ltnp | grep :${PORT}"
fi

stop_pid_if_running

###############################################################################
# Virtuelle Umgebung und Paketinstallation
###############################################################################
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  info "Erzeuge Python-venv ..."
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  success "Virtuelle Umgebung erstellt."
else
  success "Vorhandene virtuelle Umgebung wird verwendet."
fi

VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
SUPERTONIC_BIN="${VENV_DIR}/bin/supertonic"

info "Aktualisiere pip, setuptools und wheel ..."
"${VENV_PYTHON}" -m pip install --upgrade --disable-pip-version-check \
  pip setuptools wheel

info "Installiere bzw. aktualisiere Supertonic inklusive HTTP-Server ..."
# --upgrade sorgt für Supertonic 3, sofern es im Package-Index verfügbar ist.
# Keine globalen Python-Pakete werden verändert.
"${VENV_PIP}" install --upgrade --disable-pip-version-check \
  "supertonic[serve]"

[[ -x "${SUPERTONIC_BIN}" ]] || die \
  "Die Supertonic-CLI wurde nicht installiert. Prüfe pip-Ausgabe und die virtuelle Umgebung: ${VENV_DIR}"

success "Supertonic wurde installiert: $("${SUPERTONIC_BIN}" --help 2>/dev/null | head -n 1 || echo 'CLI verfügbar')"

###############################################################################
# Server starten
###############################################################################
SERVER_CMD=(
  "${SUPERTONIC_BIN}"
  serve
  --host "${HOST}"
  --port "${PORT}"
)

info "Starte offiziellen Supertonic-HTTP-Server ..."
printf '      Befehl:'
printf ' %q' "${SERVER_CMD[@]}"
printf '\n'

if [[ "${NOHUP_MODE}" == "1" ]]; then
  info "Starte im Hintergrund. Logdatei: ${LOG_FILE}"

  # Umask schützt Logdatei und ggf. heruntergeladene Dateien im Arbeitskontext.
  (
    umask 077
    exec nohup "${SERVER_CMD[@]}" >>"${LOG_FILE}" 2>&1
  ) &

  SERVER_PID="$!"
  printf '%s\n' "${SERVER_PID}" > "${PID_FILE}"

  # Der Modell-Download beim allerersten Start kann länger dauern. FastAPI sollte
  # allerdings nach der Initialisierung erreichbar sein.
  info "Warte bis zu 180 Sekunden auf den Serverstart und den ersten Modelldownload ..."
  if ! wait_for_http "http://127.0.0.1:${PORT}/docs" 180; then
    warn "Der Healthcheck war nach 180 Sekunden noch nicht erfolgreich."
    warn "Prüfe die Logs: tail -n 200 '${LOG_FILE}'"

    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      die "Der Serverprozess ist beendet. Details stehen in: ${LOG_FILE}"
    fi

    if [[ "${STRICT_HEALTHCHECK}" == "1" ]]; then
      kill "${SERVER_PID}" 2>/dev/null || true
      rm -f "${PID_FILE}"
      die "Healthcheck fehlgeschlagen (STRICT_HEALTHCHECK=1)."
    fi
  else
    success "Server ist erreichbar."
  fi

  cat <<EOF

FERTIG — Supertonic läuft im Hintergrund.

  OpenAI-kompatibler TTS-Endpoint:
  http://<DEINE-SERVER-IP>:${PORT}/v1/audio/speech

  Lokaler Test:
  curl -fsS -X POST "http://127.0.0.1:${PORT}/v1/audio/speech" \\
    -H "Content-Type: application/json" \\
    -d '{
      "model": "supertonic-3",
      "input": "Guten Abend. Das ist eine lokale deutsche Supertonic-Sprachausgabe.",
      "voice": "F1",
      "lang": "de",
      "response_format": "wav"
    }' \\
    -o supertonic-test.wav

  Dokumentation:
  http://127.0.0.1:${PORT}/docs

  Logs:
  tail -f "${LOG_FILE}"

  Stoppen:
  kill \$(cat "${PID_FILE}")

EOF
  exit 0
fi

###############################################################################
# Vordergrund-Modus
###############################################################################
cat <<EOF

FERTIG — der Server startet jetzt im Vordergrund.

  OpenAI-kompatibler Endpoint:
  http://<DEINE-SERVER-IP>:${PORT}/v1/audio/speech

  API-Dokumentation:
  http://127.0.0.1:${PORT}/docs

  Beispielrequest in einem zweiten Terminal:
  curl -fsS -X POST "http://127.0.0.1:${PORT}/v1/audio/speech" \\
    -H "Content-Type: application/json" \\
    -d '{
      "model": "supertonic-3",
      "input": "Guten Abend. Das ist eine lokale deutsche Supertonic-Sprachausgabe.",
      "voice": "F1",
      "lang": "de",
      "response_format": "wav"
    }' \\
    -o supertonic-test.wav

  Mit Ctrl+C beendest du den Server.

EOF

# exec sorgt für korrektes Signal-Handling (z.B. Ctrl+C oder systemd Stop).
exec "${SERVER_CMD[@]}"
