ffmpeg -y -f pulse -i "$(pactl get-default-sink).monitor" test.wav -loglevel error & rec=$!; sleep 1; spd-say -o ai -w "Hallo, dies ist ein Testtext."; sleep 1; kill "$rec"; wait "$rec" 2>/dev/null
