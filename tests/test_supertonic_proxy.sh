# Test 1: Langsam, speed 0.8
# Header landen separat in supertonic-speed-0.8.headers.txt.
# Die WAV-Datei enthält ausschließlich Audiodaten.
curl --fail-with-body -sS \
  -D supertonic-speed-0.8.headers.txt \
  -X POST "http://127.0.0.1:59113/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "supertonic-3",
    "voice": "F1",
    "input": "Dies ist derselbe deutsche Vergleichstext. Diese Aufnahme sollte langsam und deutlich gesprochen werden.",
    "language": "de-DE",
    "speed": 0.8,
    "response_format": "wav"
  }' \
  --output supertonic-speed-0.8.wav

# Test 2: Schnell, speed 1.9
# Header landen separat in supertonic-speed-1.9.headers.txt.
# Die WAV-Datei enthält ausschließlich Audiodaten.
curl --fail-with-body -sS \
  -D supertonic-speed-1.9.headers.txt \
  -X POST "http://127.0.0.1:59113/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "supertonic-3",
    "voice": "F1",
    "input": "Dies ist derselbe deutsche Vergleichstext. Diese Aufnahme sollte langsam und deutlich gesprochen werden.",
    "language": "de-DE",
    "speed": 1.4,
    "response_format": "wav"
  }' \
  --output supertonic-speed-1.9.wav

# Prüfen, ob die Dateien echte WAV-Dateien sind:
file supertonic-speed-0.8.wav
file supertonic-speed-1.9.wav

# Prüfen, ob der Proxy die Sprechrate wirklich weitergab:
grep -iE 'x-supertonic-(voice|requested-speed|applied-speed|speed-clamped)' \
  supertonic-speed-0.8.headers.txt

grep -iE 'x-supertonic-(voice|requested-speed|applied-speed|speed-clamped)' \
  supertonic-speed-1.9.headers.txt

# Optional abspielen:
ffplay -autoexit supertonic-speed-0.8.wav
ffplay -autoexit supertonic-speed-1.9.wav
