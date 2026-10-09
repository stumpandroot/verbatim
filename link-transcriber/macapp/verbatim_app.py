"""Verbatim desktop launcher.

Runs the FastAPI server on a free localhost port in a background thread and opens
the web interface in a native window. Packaged into Verbatim.app by build_mac.sh.

Run from source for testing:  python3 macapp/verbatim_app.py
Headless check (no window):   python3 macapp/verbatim_app.py --check
"""
from __future__ import annotations

import os
import socket
import sys
import threading
import time
import urllib.request
from pathlib import Path


def resource_dir() -> Path:
    """Folder holding app.py and static/, whether frozen by PyInstaller or run from source."""
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        return Path(frozen)
    return Path(__file__).resolve().parent.parent


def support_dir() -> Path:
    base = Path.home() / "Library" / "Application Support" / "Verbatim"
    if sys.platform != "darwin":
        base = Path.home() / ".verbatim"
    base.mkdir(parents=True, exist_ok=True)
    return base


def ollama_running() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", 11434), timeout=0.3):
            return True
    except OSError:
        return False


def configure_environment() -> None:
    res = resource_dir()
    # Bundled FFmpeg and ffprobe sit in bin/ next to app.py inside the bundle.
    bundled_bin = res / "bin"
    if bundled_bin.is_dir():
        os.environ["PATH"] = f"{bundled_bin}{os.pathsep}{os.environ.get('PATH', '')}"
    # Speech models download once into Application Support, not a hidden cache.
    models = support_dir() / "models"
    models.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(models))
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    # AI notes use Ollama only when it is actually running; otherwise the button explains itself.
    if "AI_PROVIDER" not in os.environ:
        os.environ["AI_PROVIDER"] = "ollama" if ollama_running() else "none"
    os.environ.setdefault("WHISPER_MODEL", "base")


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_server(port: int) -> threading.Thread:
    sys.path.insert(0, str(resource_dir()))
    import uvicorn  # noqa: WPS433 (import after sys.path setup)
    import app as verbatim  # app.py

    config = uvicorn.Config(verbatim.app, host="127.0.0.1", port=port, log_level="warning", loop="asyncio")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, name="verbatim-server", daemon=True)
    thread.start()
    return thread


def wait_ready(port: int, timeout: float = 20.0) -> dict:
    url = f"http://127.0.0.1:{port}/api/capabilities"
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as resp:
                import json
                return json.load(resp)
        except Exception as exc:  # server not up yet
            last_error = exc
            time.sleep(0.15)
    raise RuntimeError(f"Verbatim server did not start: {last_error}")


def open_window(port: int) -> None:
    import webview  # pywebview: native WKWebView on macOS

    window = webview.create_window(
        "Verbatim",
        f"http://127.0.0.1:{port}/",
        width=1180,
        height=800,
        min_size=(420, 640),
        text_select=True,
    )
    webview.start(debug=False)


def main() -> int:
    configure_environment()
    port = free_port()
    start_server(port)
    caps = wait_ready(port)
    if "--check" in sys.argv:
        print(f"ok port={port} ffmpeg={caps.get('ffmpeg')} ai={caps.get('ai_provider')} whisper={caps.get('whisper_model')}")
        return 0
    open_window(port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
