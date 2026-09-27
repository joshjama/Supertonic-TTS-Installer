#!/usr/bin/env bash
set -Eeuo pipefail

# Supertonic OpenAI-v1 TTS-Test
# Ziel: http://192.168.178.78:59112/v1/audio/speech
# Ausgabe: ./supertonic-test-de.wav

HOST="${HOST:-192.168.178.78}"
PORT="${PORT:-59112}"
BASE_URL="http://${HOST}:${PORT}"
ENDPOINT="${BASE_URL}/v1/audio/speech"
OUTPUT_FILE="${OUTPUT_FILE:-./supertonic-test-de.wav}"
ERROR_FILE="$(mktemp)"

cleanup() {
  rm -f "${ERROR_FILE}"
}
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1; then
  echo "FEHLER: curl ist nicht installiert."
  exit 1
fi

echo "Prüfe, ob Supertonic erreichbar ist: ${BASE_URL}"

# Der Docs-Endpoint ist ein einfacher Verfügbarkeitstest: Er benötigt keine
# Modellgenerierung und gibt Antwort, sobald FastAPI/Uvicorn aktiv ist.
if ! curl --fail --silent --show-error \
  --connect-timeout 3 \
  --max-time 10 \
  "${BASE_URL}/docs" >/dev/null; then
  echo
  echo "FEHLER: Supertonic ist unter ${BASE_URL} nicht erreichbar."
  echo
  echo "Prüfe beispielsweise:"
  echo "  ss -ltnp | grep :${PORT}"
  echo "  curl -I ${BASE_URL}/docs"
  echo
  echo "Falls der Server in einem anderen Rechner/Container läuft:"
  echo "  HOST=<IP-DES-SERVERS> ./test-supertonic.sh"
  exit 1
fi

echo "Server erreichbar. Erzeuge deutsche TTS-Ausgabe mit Stimme F1 ..."

HTTP_CODE="$(
  curl --silent --show-error \
    --connect-timeout 10 \
    --max-time 180 \
    --output "${OUTPUT_FILE}" \
    --write-out "%{http_code}" \
    -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "supertonic-3",
      "input": "Guten Abend. Dies ist ein erfolgreicher Test der lokalen deutschen Supertonic Sprachausgabe.",
      "voice": "F1",
      "lang": "de",
      "response_format": "wav"
    }' \
    || true
)"

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo
  echo "FEHLER: Die TTS-Anfrage war nicht erfolgreich (HTTP ${HTTP_CODE:-keine Antwort})."

  if [[ -f "${OUTPUT_FILE}" ]] && [[ -s "${OUTPUT_FILE}" ]]; then
    echo "Serverantwort:"
    cat "${OUTPUT_FILE}"
  fi

  rm -f "${OUTPUT_FILE}"

  echo
  echo "Öffne zur Diagnose die API-Dokumentation:"
  echo "  ${BASE_URL}/docs"
  exit 1
fi

if [[ ! -s "${OUTPUT_FILE}" ]]; then
  echo "FEHLER: Der Server hat HTTP 200 geliefert, aber keine Audiodatei erzeugt."
  exit 1
fi

# Prüft den Dateityp; file ist nicht zwingend notwendig.
if command -v file >/dev/null 2>&1; then
  FILE_TYPE="$(file -b "${OUTPUT_FILE}" || true)"
  echo "Dateityp: ${FILE_TYPE}"

  if ! grep -qiE 'WAVE|RIFF|audio' <<<"${FILE_TYPE}"; then
    echo "WARNUNG: Die Antwort sieht nicht eindeutig wie eine WAV-Datei aus."
    echo "Inhalt zur Kontrolle:"
    head -c 500 "${OUTPUT_FILE}" || true
    echo
  fi
fi

echo
echo "ERFOLG: Audiodatei wurde erzeugt:"
echo "  ${OUTPUT_FILE}"
echo
echo "Abspielen, falls vorhanden:"
echo "  ffplay -autoexit \"${OUTPUT_FILE}\""
echo
echo "Oder mit VLC / deinem Dateimanager öffnen."
