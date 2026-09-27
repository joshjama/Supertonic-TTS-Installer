# Supertonic Open WebUI Proxy and Server

- Created with Perplexity.ai 

## What is this?

This setup runs **Supertonic TTS locally** and makes it available to **Open WebUI** through an OpenAI-compatible Text-to-Speech API.

It consists of two systemd services:

| Service | Script | Port | Purpose |
|---|---|---:|---|
| `supertonic-tts.service` | `/home/tts/tts-server-supertonic/start_tts-server-supertonic-tts.sh` | `59112` | Starts the native local Supertonic TTS server |
| `supertonic-proxy.service` | `/home/tts/tts-server-supertonic/start_tts-server-supertonic-tts-proxy.sh` | `59113` | Starts the OpenAI-compatible proxy for Open WebUI |

The proxy listens on port `59113` and forwards requests to the native local Supertonic server on port `59112`.

```text
Open WebUI
    |
    | POST /v1/audio/speech
    v
Supertonic OpenAI Proxy
Port 59113
    |
    | POST /v1/tts
    v
Native Supertonic TTS server
Port 59112
```

Open WebUI expects an OpenAI-compatible speech endpoint:

```text
POST /v1/audio/speech
```

The native Supertonic server uses its own endpoint:

```text
POST /v1/tts
```

The proxy translates between the two APIs. It forwards the selected `voice`, `speed`, `language`, `response_format`, and optional `total_steps` parameters to Supertonic.

The proxy does **not** load a second model and does **not** modify the native Supertonic server.

---

- The Speech-Dispatcher module integrates the project into your screen-reader orca. 

## Requirements 

- ffmpeg 
- python3-pip 
- python3-venv 

### System requirements

- On a fresh Debian or Linux Mint installation, run this before the project’s installation script:

```bash
sudo apt update
sudo apt install speech-dispatcher python3 python3-venv python3-pip \
  python3-dev portaudio19-dev build-essential ffmpeg
```

`python3-venv` and `python3-pip` support the Python installation. `python3-dev`, `portaudio19-dev`, and `build-essential` provide the build dependencies for PyAudio. `ffmpeg` is required for the current playback-speed processing. **Python packages are not listed here** because the project’s installation script installs them. [pypi](https://pypi.org/project/PyAudio/)
## Installation

The scripts are located in:

```text
/home/tts/tts-server-supertonic/
```

Expected files:

```text
/home/tts/tts-server-supertonic/
├── start_tts-server-supertonic-tts.sh
└── start_tts-server-supertonic-tts-proxy.sh
```

The systemd service files are located in:

```text
/etc/systemd/system/
```

Expected service files:

```text
/etc/systemd/system/supertonic-tts.service
/etc/systemd/system/supertonic-proxy.service
```

After copying or editing a service file, reload systemd:

```bash
sudo systemctl daemon-reload
```

Start the native Supertonic TTS server first:

```bash
sudo systemctl start supertonic-tts
```

Then start the OpenAI-compatible proxy:

```bash
sudo systemctl start supertonic-proxy
```

Enable both services to start automatically after reboot:

```bash
sudo systemctl enable supertonic-tts
sudo systemctl enable supertonic-proxy
```

Check service status:

```bash
sudo systemctl status supertonic-tts
sudo systemctl status supertonic-proxy
```

Follow logs live:

```bash
sudo journalctl -u supertonic-tts -f
```

```bash
sudo journalctl -u supertonic-proxy -f
```

- If the system services do crash after reboot just add the following line to your roots crontab : 
@reboot systemctl restart supertonic-tts && sleep 20 && systemctl restart supertonic-proxy

### Speech Dispatcher configuration

- Thanks to [speechd-ai](https://codeberg.org/sachac/speechd-ai.git).
- This work builds on the foundational help provided by that project.

This section supplements the existing README. You need the project directory containing `speechd_ai_wrapper`, `speechd_ai.conf`, the installation script already included with the project, and `show-speechd-ai-addmodule.sh`. Your OpenAI-compatible TTS server must be reachable.

### Installation

1. In the project directory, run the **installation script already included with the project**, as described earlier in the README. Also run the installer in the `speech-dispatcher` directory:

   ~~~bash
   cd speech-dispatcher
   ./install_speechd_ai.sh
   ~~~

2. Enter your TTS endpoint address, model, and default voice in `speechd_ai.conf`. If these values are already correct, you do not need to change anything.

3. From the project directory, display the appropriate module line:

   ~~~bash
   cd speech-dispatcher
   ./show-speechd-ai-addmodule.sh
   ~~~

4. Copy the **actual** `AddModule "ai" ...` line printed by the script into the Speech Dispatcher configuration you use, alongside the other `AddModule` lines. The system-wide configuration is normally `/etc/speech-dispatcher/speechd.conf`; alternatively, you may be using `~/.config/speech-dispatcher/speechd.conf`. Do not move the project afterward without updating the paths in that line.

5. **Restart Speech Dispatcher** so it loads the new line:

   ~~~bash
   systemctl --user restart speech-dispatcher.service
   ~~~

6. Check that `ai` appears and produces speech:

   ~~~bash
   spd-say -O
   spd-say -o ai "Speech output test"
   ~~~

The helper script only displays the line; it does not add it to the configuration. Editing the system-wide configuration requires administrator privileges.

### Configure multiple fixed voices

If you want to use different Supertonic voices without relying on the voice list, which is not yet reliable, you can register **one Speech Dispatcher module per voice**. Each module uses the same wrapper but its own copy of `speechd_ai.conf` with a different `DefaultVoice` value. In Orca, you then select the module instead of a voice from the module's voice list.

For example, to configure two voices, keep `DefaultVoice F1` in `speechd_ai.conf`, copy the file to `speechd_ai-f2.conf`, and change the line **in the copy** to `DefaultVoice F2`:

~~~bash
cp speechd_ai.conf speechd_ai-f2.conf
~~~

Use the `AddModule` line generated by the helper script twice. Leave the first line unchanged. In the second line, change only the module name to `ai-f2` and the configuration file path to `speechd_ai-f2.conf`; keep the absolute wrapper path the same. The following is **schematic**—replace the example paths with the absolute paths from your output:

~~~text
AddModule "ai" "/ABSOLUTE/PROJECT/PATH/speechd_ai_wrapper" "/ABSOLUTE/PROJECT/PATH/speechd_ai.conf"
AddModule "ai-f2" "/ABSOLUTE/PROJECT/PATH/speechd_ai_wrapper" "/ABSOLUTE/PROJECT/PATH/speechd_ai-f2.conf"
~~~

After restarting Speech Dispatcher, both `ai` and `ai-f2` should appear in `spd-say -O`. Test the second module with `spd-say -o ai-f2 "Test with F2"`. For additional voices, repeat the process, giving each configuration file and module a **unique** name. This approach does not require a dynamic voice list and does not query the TTS proxy for available voices.

Supertonic provides these ten built-in voices ([voice overview](https://supertone-inc.github.io/supertonic-py/voices/)):

| Female voices | Male voices |
| --- | --- |
| `F1` | `M1` |
| `F2` | `M2` |
| `F3` | `M3` |
| `F4` | `M4` |
| `F5` | `M5` |

These names are the values for `DefaultVoice`. Use the corresponding `spd-say -o MODULE_NAME` test to check whether your **particular** OpenAI-compatible proxy accepts them unchanged.

### Important for Orca users

Restarting Speech Dispatcher **may temporarily leave you without speech output**, especially if there is a configuration error. Ideally, set up **a second Orca profile with a speech module that already works** beforehand. In Orca's key bindings, assign an easy-to-reach shortcut to **“Cycle to the next profile”** and test it while speech output still works. This command has no default key binding ([Orca profile commands](https://help.gnome.org/users/orca/stable/commands_profiles.html.en)). A second profile makes it easier to switch back, but it cannot guarantee speech output if Speech Dispatcher itself fails.

The voice list within an individual `ai` module is not yet reliably implemented. Check the **module list** first with `spd-say -O`, rather than the voice list with `spd-say -o ai -L`. The Python module writes its own log to `${TMPDIR:-/tmp}/speechd_ai.log`; do not publish confidential text or credentials from that log.

You may need to reboot the system if Speech Dispatcher cannot find D-Bus.


## Usage

### Speech-Dispatcher 

- You can use the speed controlls with the current speechd_ai.py and speechd_ai.conf but it may be a litle bit slow doto ffmpeg consuming much cpu efforts. 
- If it is to slow to be helpfull. replace speechd_ai.py and speechd_ai.conf with 
speechd_ai.py_performant and speechd_ai.conf_performant by renaming them to speechd_ai.py and speechd_ai.conf. 
- Note that your are no longer able to change the speed in this case. 

### Service addresses

| Component | Address | Endpoint |
|---|---|---|
| Native Supertonic server | `http://127.0.0.1:59112` | `POST /v1/tts` |
| OpenAI-compatible proxy | `http://127.0.0.1:59113` | `POST /v1/audio/speech` |
| Proxy health check | `http://127.0.0.1:59113/health` | `GET /health` |
| Proxy model list | `http://127.0.0.1:59113/v1/models` | `GET /v1/models` |

Check whether the proxy and native backend are healthy:

```bash
curl -fsS http://127.0.0.1:59113/health
```

List the model exposed by the proxy:

```bash
curl -fsS http://127.0.0.1:59113/v1/models
```

### Direct TTS test

Create a German WAV file through the OpenAI-compatible proxy:

```bash
curl --fail-with-body -sS \
  -D supertonic-test.headers.txt \
  -X POST "http://127.0.0.1:59113/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "supertonic-3",
    "voice": "F1",
    "input": "Hallo. Dies ist ein Test der lokalen Supertonic Sprachausgabe über den OpenAI kompatiblen Proxy.",
    "language": "de-DE",
    "speed": 1.2,
    "response_format": "wav"
  }' \
  --output supertonic-test.wav
```

Verify that the output is a valid WAV file:

```bash
file supertonic-test.wav
```

Inspect the settings actually applied by the proxy:

```bash
grep -iE 'x-supertonic-(voice|language|requested-speed|applied-speed|total-steps)' \
  supertonic-test.headers.txt
```

Play the file if FFmpeg is installed:

```bash
ffplay -autoexit supertonic-test.wav
```

### Voices

Set the desired voice in the request or Open WebUI.

Common built-in preset voices:

| Voice | Description |
|---|---|
| `F1` | Female preset voice |
| `M1` | Male preset voice |

Use the male voice in a direct request:

```json
{
  "voice": "M1"
}
```

The proxy forwards the selected voice to Supertonic. It does not hard-code `F1`; `F1` is only used as a fallback when no voice is supplied.

### Speech speed

Supertonic supports this native speech-rate range:

```text
0.7 to 2.0
```

Useful values:

| Value | Effect |
|---:|---|
| `0.8` | Slow and clear |
| `1.05` | Typical default speed |
| `1.2` | Moderately faster |
| `1.4` to `1.5` | Fast but usually understandable |
| `2.0` | Maximum native Supertonic speed |

Values outside this range are clamped by the proxy before being sent to Supertonic.

### Quality steps

The proxy can forward the Supertonic-native `total_steps` parameter.

| `total_steps` | Typical effect |
|---:|---|
| `5` to `6` | Faster generation, potentially less stable reading |
| `8` | Balanced default |
| `10` | Higher stability for normal text |
| `12` | Highest quality/stability, slower generation |

Example request with voice, speed, and quality steps:

```bash
curl --fail-with-body -sS \
  -X POST "http://127.0.0.1:59113/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "supertonic-3",
    "voice": "M1",
    "input": "Dies ist ein Test mit einer männlichen Stimme, erhöhter Sprechgeschwindigkeit und zehn Syntheseschritten.",
    "language": "de",
    "speed": 1.4,
    "total_steps": 10,
    "response_format": "wav"
  }' \
  --output supertonic-m1.wav
```

The regular Open WebUI user interface may expose voice and speed but usually does not expose `total_steps`. In that case, the proxy uses its configured default value.

---

## Open WebUI configuration

Open WebUI must connect to the proxy on port `59113`, **not** directly to the native Supertonic server on port `59112`.

Open Open WebUI and navigate to:

```text
Admin Panel → Settings → Audio → Text-to-Speech
```

### Open WebUI directly on the host

Use these values if Open WebUI runs directly on this Linux host:

| Open WebUI setting | Value |
|---|---|
| Text-to-Speech Engine | `OpenAI` |
| API Base URL | `http://127.0.0.1:59113/v1` |
| API Key | A non-empty value, for example `local` |
| TTS Model | `supertonic-3` |
| TTS Voice | `F1` or `M1` |
| Speed | `1.2` as a good starting point |

### Open WebUI in Docker

Use these values if Open WebUI runs in Docker on the same Linux host:

| Open WebUI setting | Value |
|---|---|
| Text-to-Speech Engine | `OpenAI` |
| API Base URL | `http://host.docker.internal:59113/v1` |
| API Key | A non-empty value, for example `local` |
| TTS Model | `supertonic-3` |
| TTS Voice | `F1` or `M1` |
| Speed | `1.2` as a good starting point |

On Linux, `host.docker.internal` may require an explicit host gateway mapping in the Open WebUI Docker Compose configuration:

```yaml
services:
  open-webui:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Restart Open WebUI afterwards:

```bash
docker compose up -d
```

### Recommended Open WebUI values

For German chat responses:

```text
TTS Voice: F1
Speed:     1.2
```

For a male voice:

```text
TTS Voice: M1
Speed:     1.2
```

If you change voice or speed, generate a new speech output. Existing audio files are not regenerated automatically.

---

## Troubleshooting

### Native server is not running

Check the service:

```bash
sudo systemctl status supertonic-tts
```

Read recent logs:

```bash
sudo journalctl -u supertonic-tts -n 100 --no-pager
```

Check whether its API documentation is reachable:

```bash
curl -I http://127.0.0.1:59112/docs
```

### Proxy is not running

Check the proxy service:

```bash
sudo systemctl status supertonic-proxy
```

Read recent logs:

```bash
sudo journalctl -u supertonic-proxy -n 100 --no-pager
```

Check the proxy health endpoint:

```bash
curl -fsS http://127.0.0.1:59113/health
```

### Open WebUI cannot reach the proxy

If Open WebUI runs in Docker, do **not** use this address:

```text
http://127.0.0.1:59113/v1
```

Inside a Docker container, `127.0.0.1` refers to the container itself, not the Linux host.

Use:

```text
http://host.docker.internal:59113/v1
```

If needed, add this Docker Compose setting:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

### Audio file is invalid

Do not use `curl -i` together with `--output output.wav`.

The `-i` option writes HTTP headers into the generated WAV file, which corrupts the audio file.

Use `-D headers.txt` instead:

```bash
curl -sS \
  -D response.headers.txt \
  -X POST "http://127.0.0.1:59113/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "supertonic-3",
    "voice": "F1",
    "input": "Kurzer WAV Test.",
    "language": "de",
    "speed": 1.0,
    "response_format": "wav"
  }' \
  --output output.wav
```

### Speed does not change

Verify that Open WebUI points to the proxy on port `59113`, not directly to Supertonic on port `59112`.

Correct URL:

```text
http://127.0.0.1:59113/v1
```

For Open WebUI running in Docker:

```text
http://host.docker.internal:59113/v1
```

Test whether the proxy received and applied the requested speed:

```bash
curl --fail-with-body -sS \
  -D speed.headers.txt \
  -X POST "http://127.0.0.1:59113/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "supertonic-3",
    "voice": "F1",
    "input": "Dies ist ein Test der Sprechgeschwindigkeit.",
    "language": "de",
    "speed": 1.9,
    "response_format": "wav"
  }' \
  --output speed-test.wav

grep -iE 'x-supertonic-(requested-speed|applied-speed|voice)' \
  speed.headers.txt
```

Expected headers:

```text
X-Supertonic-Requested-Speed: 1.9
X-Supertonic-Applied-Speed: 1.9
X-Supertonic-Voice: F1
```

### Parts of text are missing

The proxy sends the complete original text to Supertonic without manual splitting. Supertonic handles long-text chunking itself.

If Supertonic skips spoken words:

- Reduce `speed`, for example from `1.5` to `1.2`.
- Increase `total_steps` in the proxy configuration, for example from `8` to `10` or `12`.
- Test the exact same text directly through the native endpoint on port `59112`.
- Try the other built-in voice, such as `M1` instead of `F1`.

---

## Service management

Restart both services:

```bash
sudo systemctl restart supertonic-tts
sudo systemctl restart supertonic-proxy
```

Restart only the proxy after changing proxy behavior:

```bash
sudo systemctl restart supertonic-proxy
```

Stop both services:

```bash
sudo systemctl stop supertonic-proxy
sudo systemctl stop supertonic-tts
```

Disable automatic startup:

```bash
sudo systemctl disable supertonic-proxy
sudo systemctl disable supertonic-tts
```

## For Open Web UI 

* Just use localhost:59113/v1 as base url 
* use supertonic-3 as model 
* use F1 to F5 or M1 to M5 as voice. 

Reload systemd after editing either `.service` file:

```bash
sudo systemctl daemon-reload
```

---

## Security note

Keep the native Supertonic server bound to `127.0.0.1` where possible. The proxy on port `59113` should be the only API integration point.

If port `59113` is reachable from other devices or from the internet:

- Configure `PROXY_API_KEY` in the proxy service.
- Restrict access using a firewall.
- Put Caddy, Nginx, or another reverse proxy with HTTPS in front of the service.
- Do not expose port `59112` directly to untrusted networks.


== If the systemd service fails after reboot 

* Place the folloing line into your roots crontab 
* @reboot systemctl restart supertonic-tts && sleep 20 && systemctl restart supertonic-proxy

== Attension ! This is ment to be used locally, do not use it in unsecure network environments 

* You are opening 59112 and 59113 asports. There is no savety controll behind this ports. Do not expose them to insecure networks. Use it at home or within your vpn. 
* Please also note that this is early work in progress, so it may crash in some cases. Be sure to have a Backup - strategy especially if you are a visualy impaired person. If you want to rebuild the state before installation just delete the AddModule line within your Speech-Dispatcher installation and the virtual env within here. 
