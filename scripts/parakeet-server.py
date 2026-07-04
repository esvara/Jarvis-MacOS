#!/usr/bin/env python3
"""Tiny local STT server for Jarvis: Parakeet-TDT 0.6B v3 on MLX.

Loads the model once and serves POST /transcribe (raw WAV body) on
127.0.0.1:4821, returning {"text": "..."}. GET /health reports readiness.
Run inside the venv created by scripts/setup-parakeet.sh; managed by the
com.jarvis.parakeet LaunchAgent.
"""

import io
import json
import os
import queue
import threading
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("JARVIS_STT_PORT", "4821"))
MODEL_ID = os.environ.get("JARVIS_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
MAX_BODY_BYTES = 32 * 1024 * 1024  # ~5 min of 16 kHz mono WAV

_model = None
_model_error = None
# MLX streams are thread-local: the model must be loaded AND run from the
# same thread, so all inference goes through this single worker queue.
_jobs = queue.Queue()


def _worker():
    global _model, _model_error
    try:
        from parakeet_mlx import from_pretrained

        _model = from_pretrained(MODEL_ID)
    except Exception as error:  # noqa: BLE001 — surfaced via /health
        _model_error = str(error)

    while True:
        wav_bytes, reply = _jobs.get()
        if _model is None:
            reply.put(("error", _model_error or "model failed to load"))
            continue
        try:
            reply.put(("ok", transcribe_wav(_model, wav_bytes)))
        except Exception as error:  # noqa: BLE001
            reply.put(("error", str(error)))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the LaunchAgent log quiet
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            self._send(404, {"error": "not found"})
            return
        ready = _model is not None
        self._send(200, {"ok": True, "model": MODEL_ID, "ready": ready, "error": _model_error})

    def do_POST(self):
        if self.path != "/transcribe":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send(400, {"error": "invalid body size"})
            return
        audio = self.rfile.read(length)

        if _model is None:
            self._send(503, {"error": _model_error or "model still loading"})
            return

        reply = __import__("queue").Queue()
        _jobs.put((audio, reply))
        status, payload = reply.get(timeout=60)
        if status == "ok":
            self._send(200, {"text": payload})
        else:
            self._send(500, {"error": payload})


def transcribe_wav(model, wav_bytes):
    """Decode a PCM WAV with the stdlib and run the model directly.

    Mirrors parakeet_mlx's transcribe() for short clips but skips its
    ffmpeg-based load_audio — the Jarvis client always sends 16 kHz mono
    16-bit WAV, which needs no external decoder.
    """
    import mlx.core as mx
    import numpy as np
    from parakeet_mlx.audio import get_logmel

    with wave.open(io.BytesIO(wav_bytes), "rb") as reader:
        rate = reader.getframerate()
        channels = reader.getnchannels()
        width = reader.getsampwidth()
        frames = reader.readframes(reader.getnframes())
    if width != 2:
        raise ValueError("expected 16-bit PCM WAV")

    samples = np.frombuffer(frames, np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    target_rate = model.preprocessor_config.sample_rate
    if rate != target_rate:
        positions = np.arange(0, len(samples), rate / target_rate)
        samples = np.interp(positions, np.arange(len(samples)), samples).astype(np.float32)

    mel = get_logmel(mx.array(samples), model.preprocessor_config)
    result = model.generate(mel)[0]
    return (result.text or "").strip()


def main():
    # The worker loads the model (so /health responds immediately) and then
    # serves inference jobs from its own thread.
    threading.Thread(target=_worker, daemon=True).start()
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"parakeet-server listening on 127.0.0.1:{PORT} model={MODEL_ID}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
