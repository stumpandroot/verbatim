import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as backend
from fastapi.testclient import TestClient


client = TestClient(backend.app)


def test_homepage_is_served():
    response = client.get("/")
    assert response.status_code == 200
    assert "Get transcript" in response.text and "viewport-fit=cover" in response.text


def test_health():
    assert client.get("/api/health").json() == {"ok": True}


def test_valid_urls():
    for url in (
        "https://www.youtube.com/watch?v=abc123", "https://youtu.be/abc123?t=20",
        "https://vimeo.com/1234567", "https://player.vimeo.com/video/1234567",
        "https://vimeo.com/123456/abcdef", "https://m.youtube.com/shorts/abc123",
    ):
        assert backend.validate_video_url(url) == url


def test_invalid_urls():
    for url in (
        "http://youtube.com/watch?v=x", "https://youtube.com.evil.test/watch?v=x",
        "https://127.0.0.1:8000/watch?v=x", "file:///etc/passwd",
        "https://evil.test/vimeo.com/123", "https://vimeo.com/", "https://youtube.com/watch",
        "https://user:pass@vimeo.com/123", "https://vimeo.com:444/123",
        "https://youtube.com@evil.test/watch?v=x", "https://www.youtube.com/watch?v=abc 123",
    ):
        try:
            backend.validate_video_url(url)
        except ValueError:
            continue
        assert False, f"Should have rejected: {url}"


def test_supported_social_video_urls():
    examples = {
        "TikTok": ["https://www.tiktok.com/@filmmaker/video/7431234567890123456?is_from_webapp=1",
                   "https://vm.tiktok.com/ZMhRkAnN/", "https://vt.tiktok.com/ZSAbcDeF/"],
        "Instagram": ["https://www.instagram.com/reel/DBabc-123/", "https://instagram.com/p/DF00x/"],
        "Facebook": ["https://www.facebook.com/reel/1234567890", "https://fb.watch/aBC123/",
                     "https://www.facebook.com/watch/?v=1234567"],
        "X / Twitter": ["https://x.com/someone/status/1871234567890123456",
                         "https://twitter.com/i/status/1871234567890123456"],
        "Reddit": ["https://www.reddit.com/r/videos/comments/1abcxyz/a_video/",
                   "https://v.redd.it/abc123"],
        "Twitch": ["https://www.twitch.tv/videos/1234567", "https://clips.twitch.tv/ExampleClip"],
        "Dailymotion": ["https://www.dailymotion.com/video/x99abc", "https://dai.ly/x99abc"],
        "LinkedIn": ["https://www.linkedin.com/posts/person_activity-1234567890-abc"],
        "Loom": ["https://www.loom.com/share/abcdef1234"],
        "Streamable": ["https://streamable.com/abc123"],
        "Rumble": ["https://rumble.com/v6abc1-example-title.html"],
        "Pinterest": ["https://www.pinterest.com/pin/1234567890/", "https://pin.it/AbcDEF"],
        "Bluesky": ["https://bsky.app/profile/person.bsky.social/post/3kxyz"],
    }
    for platform, urls in examples.items():
        for url in urls:
            assert backend.validate_video_url(url) == url, (platform, url)
            host = backend.urlsplit(url).hostname
            assert backend.HOST_TO_PLATFORM[host] == platform


def test_social_profile_and_unsafe_urls_rejected():
    urls = (
        "https://www.tiktok.com/@creator", "https://www.instagram.com/creator/",
        "https://www.facebook.com/somecreator", "https://x.com/someone",
        "https://www.reddit.com/r/videos/", "https://www.twitch.tv/streamer",
        "https://www.linkedin.com/company/something/", "https://bsky.app/profile/person.bsky.social",
        "https://www.pinterest.com/person/", "https://www.dailymotion.com/playlist/x123",
        "https://vm.tiktok.com.evil.test/ZSAbcDeF/", "https://127.0.0.1/creator/video/123",
        "https://attacker@www.tiktok.com/@creator/video/123", "https://www.instagram.com:8080/reel/abc/",
        "http://www.tiktok.com/@creator/video/123",
    )
    for url in urls:
        try:
            backend.validate_video_url(url)
        except ValueError:
            continue
        raise AssertionError(f"Should have rejected {url}")


def test_social_caption_host_allowlist():
    assert backend._safe_caption_url("https://p16-sign.tiktokcdn.com/path/subtitle.vtt")
    assert backend._safe_caption_url("https://scontent.cdninstagram.com/path/file.srt")
    assert backend._safe_caption_url("https://video.twimg.com/path/subs.vtt")
    assert backend._safe_caption_url("https://media.licdn.com/path/subs.vtt")
    assert not backend._safe_caption_url("https://tiktokcdn.com.attacker.test/subs.vtt")
    assert not backend._safe_caption_url("https://localhost/subs.vtt")


def test_tiktok_embedded_caption_metadata_needs_no_download(monkeypatch):
    from types import SimpleNamespace
    class FakeYoutubeDL:
        def __init__(self, options): self.options = options
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def extract_info(self, url, download=False):
            return {"title": "Short TikTok talk", "extractor_key": "TikTok", "duration": 45,
                    "subtitles": {"en": [{"ext": "srt", "data": "1\n00:00:00,500 --> 00:00:03,000\nAn existing caption.\n"}]}}
        def download(self, urls):
            raise AssertionError("Audio should not be downloaded when inline captions exist")
    monkeypatch.setitem(sys.modules, "yt_dlp", SimpleNamespace(YoutubeDL=FakeYoutubeDL))
    job = backend.Job(id="short", url="https://www.tiktok.com/@creator/video/123456", language="auto")
    backend.process_video(job)
    assert job.status == "completed"
    assert job.platform == "TikTok"
    assert job.source_type == "platform_captions"
    assert job.segments == [{"start": .5, "end": 3., "text": "An existing caption."}]


def test_tiktok_json_caption_format():
    caption = '{"utterances":[{"start_time":1500,"end_time":3000,"text":"Hi there"},' \
              '{"start_time":3500,"end_time":4200,"text":"Welcome back"}]}'
    rows = backend.parse_captions(caption, "json")
    assert rows == [{"start": 1.5, "end": 3.0, "text": "Hi there"},
                    {"start": 3.5, "end": 4.2, "text": "Welcome back"}]
    meta = {"extractor_key": "TikTok", "subtitles": {"en": [{"ext": "json", "data": caption}]}}
    result = backend.get_metadata_captions(meta, "en")
    assert result[0] == rows
    assert result[1]["source_type"] == "platform_captions"


def test_tiktok_with_no_captions_falls_back_to_whisper(monkeypatch):
    from types import SimpleNamespace
    class FakeYoutubeDL:
        def __init__(self, options): self.options = options
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def extract_info(self, url, download=False):
            return {"title": "TikTok without captions", "extractor_key": "TikTok", "duration": 9}
        def download(self, urls):
            Path(self.options["outtmpl"].replace("%(ext)s", "mp4")).write_bytes(b"mock audio/video")
    class FakeModel:
        def transcribe(self, path, language, beam_size, vad_filter, condition_on_previous_text):
            return iter([SimpleNamespace(start=0, end=3, text="Hello from the video")]), \
                SimpleNamespace(language="en", duration=9)
    monkeypatch.setitem(sys.modules, "yt_dlp", SimpleNamespace(YoutubeDL=FakeYoutubeDL))
    monkeypatch.setattr(backend, "load_model", lambda: FakeModel())
    job = backend.Job(id="social-fallback", url="https://vm.tiktok.com/ZMhRkAnN/", language="auto")
    backend.process_video(job)
    assert job.status == "completed"
    assert job.platform == "TikTok"
    assert job.source_type == "speech_recognition"
    assert job.segments[0]["text"] == "Hello from the video"


def test_job_api(monkeypatch):
    class FakeThread:
        def __init__(self, target, args, daemon):
            self.target, self.args = target, args
        def start(self):
            pass
    monkeypatch.setattr(backend.threading, "Thread", FakeThread)
    response = client.post("/api/jobs", json={"url":"https://vimeo.com/123456", "language":"auto"})
    assert response.status_code == 202
    job_id = response.json()["job_id"]
    status = client.get(f"/api/jobs/{job_id}")
    assert status.status_code == 200
    assert status.json()["status"] == "queued"
    assert status.json()["segments"] == []
    backend._jobs.pop(job_id)


def test_invalid_api_link():
    response = client.post("/api/jobs", json={"url":"https://example.com/video", "language":"auto"})
    assert response.status_code == 422


def test_invalid_api_language():
    response = client.post("/api/jobs", json={"url":"https://vimeo.com/123456", "language":"invalid"})
    assert response.status_code == 422


def test_missing_job():
    assert client.get("/api/jobs/does-not-exist").status_code == 404


def test_transcription_pipeline_without_network(monkeypatch, tmp_path):
    """Exercise download + transcription orchestration with controlled substitutes."""
    from types import SimpleNamespace

    class FakeYoutubeDL:
        def __init__(self, options):
            self.options = options
        def __enter__(self):
            return self
        def __exit__(self, *args):
            pass
        def extract_info(self, url, download=False):
            return {"title": "Example talk", "duration": 63.0, "id": "123"}
        def download(self, urls):
            path = Path(self.options["outtmpl"].replace("%(ext)s", "mp3"))
            path.write_bytes(b"mock audio")
            self.options["progress_hooks"][0]({"status": "downloading", "downloaded_bytes": 100, "total_bytes": 100})

    class FakeModel:
        def transcribe(self, path, language, beam_size, vad_filter, condition_on_previous_text):
            assert Path(path).read_bytes() == b"mock audio"
            return iter([SimpleNamespace(start=0, end=4.2, text=" This is a test."),
                         SimpleNamespace(start=4.2, end=8.2, text=" Another sentence.")]), SimpleNamespace(language="en", duration=63.0)

    monkeypatch.setitem(sys.modules, "yt_dlp", SimpleNamespace(YoutubeDL=FakeYoutubeDL))
    monkeypatch.setattr(backend, "load_model", lambda: FakeModel())
    job = backend.Job(id="mockjob", url="https://vimeo.com/123456", language="auto")
    backend.process_video(job)
    assert job.status == "completed"
    assert job.progress == 100
    assert job.title == "Example talk"
    assert job.detected_language == "en"
    assert [s["text"] for s in job.segments] == ["This is a test.", "Another sentence."]


def test_vimeo_unlisted_hash_and_player_links():
    assert backend.vimeo_identifiers("https://vimeo.com/1233805867/a0dd3187f8?fl=pl") == ("1233805867", "a0dd3187f8")
    assert backend.vimeo_identifiers("https://player.vimeo.com/video/1233805867?h=a0dd3187f8") == ("1233805867", "a0dd3187f8")
    assert backend.vimeo_identifiers("https://youtu.be/abc123") is None


def test_parse_vtt_and_srt():
    vtt = """WEBVTT

00:00:00.000 --> 00:00:02.500
<i>Hello</i>, &amp; welcome.

4
00:00:03.100 --> 00:00:04.750
Second sentence.
"""
    rows = backend.parse_captions(vtt)
    assert rows == [
        {"start": 0, "end": 2.5, "text": "Hello, & welcome."},
        {"start": 3.1, "end": 4.75, "text": "Second sentence."},
    ]
    srt = "1\n00:00:01,200 --> 00:00:03,450\nHello again.\n"
    assert backend.parse_captions(srt, "srt")[0]["start"] == 1.2


def test_parse_json3_and_bad_caption_urls():
    import json
    text = json.dumps({"events": [
        {"tStartMs": 1200, "dDurationMs": 3000, "segs": [{"utf8": "First "}, {"utf8": "caption"}]},
        {"tStartMs": 5000},
    ]})
    assert backend.parse_captions(text, "json3") == [{"start": 1.2, "end": 4.2, "text": "First caption"}]
    for url in ("http://player.vimeo.com/captions.vtt", "https://127.0.0.1/internal",
                "https://vimeo.com.evil.test/foo", "https://vimeo.com@evil.test/foo"):
        assert not backend._safe_caption_url(url)
    assert backend._safe_caption_url("https://vod-adaptive-ak.vimeocdn.com/video/texttrack.vtt")


def test_caption_selection_prefers_uploaded_over_auto():
    tracks = [
        {"url": "https://www.youtube.com/autocaption", "lang": "en", "ext": "vtt", "automatic": True},
        {"url": "https://www.youtube.com/human", "lang": "es", "ext": "vtt", "automatic": False},
    ]
    assert backend._pick_caption(tracks, "auto")["lang"] == "es"
    assert backend._pick_caption(tracks, "en")["automatic"] is True


def test_vimeo_caption_fallback_without_media_download(monkeypatch):
    config = {"video": {"title": "An unlisted film", "duration": 14},
              "request": {"text_tracks": [{"lang": "en", "url": "/texttrack/123.vtt", "label": "English"}]}}
    requests = []
    def stub(url, *, json_result=False):
        requests.append(url)
        if json_result:
            return config
        return "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nA better subtitle.\n"
    monkeypatch.setattr(backend, "_request_caption_url", stub)
    job = backend.Job(id="vimeo", url="https://vimeo.com/1233805867/a0dd3187f8", language="auto")
    backend.process_video(job)
    assert requests[0] == "https://player.vimeo.com/video/1233805867/config?h=a0dd3187f8"
    assert job.status == "completed"
    assert job.source_type == "creator_captions"
    assert job.segments[0]["text"] == "A better subtitle."
    assert job.title == "An unlisted film"


def test_metadata_captions_no_audio_download(monkeypatch):
    from types import SimpleNamespace
    class FakeYoutubeDL:
        def __init__(self, options):
            self.options = options
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def extract_info(self, url, download=False):
            return {"title": "YouTube Talk", "duration": 40, "subtitles": {
                "en": [{"ext": "vtt", "url": "https://www.youtube.com/api/timedtext?id=abc"}]}}
        def download(self, urls):
            raise AssertionError("Should never download audio if captions exist")
    monkeypatch.setitem(sys.modules, "yt_dlp", SimpleNamespace(YoutubeDL=FakeYoutubeDL))
    monkeypatch.setattr(backend, "_request_caption_url", lambda *a, **kw: "WEBVTT\n\n00:00:04.500 --> 00:00:06.000\nThis is captioned.\n")
    job = backend.Job(id="youtube", url="https://www.youtube.com/watch?v=abc", language="auto")
    backend.process_video(job)
    assert job.source_type == "creator_captions"
    assert job.status == "completed"
    assert job.segments[0]["start"] == 4.5


def test_refinement_preserves_original_and_detects_uncertainty(monkeypatch):
    responses = iter([
        {"cleaned_text": "Welcome, Mayor Kline. We talked about the story.",
         "uncertainties": [{"phrase": "Mayor Kline", "reason": "Proper name unclear", "time_seconds": 1}],
         "key_points": [{"point": "Introduced the speaker.", "time_seconds": 0}]},
        {"summary": [{"point": "The speaker was introduced.", "time_seconds": 0}]},
    ])
    monkeypatch.setattr(backend, "_ai_json", lambda p: next(responses))
    job = backend.Job(id="refine", url="https://vimeo.com/123", language="auto", status="completed",
                      duration=20, segments=[{"start": 0, "end": 4, "text": "Welcum mayor cline we talked about the story."}])
    before = [dict(s) for s in job.segments]
    backend.refine_video(job)
    assert job.refine_status == "completed"
    assert job.segments == before
    assert "Welcome, Mayor Kline" in job.cleaned_text
    assert job.review_flags[0]["phrase"] == "Mayor Kline"
    assert job.summary_points[0]["time_seconds"] == 0


def test_refinement_failures_keep_original(monkeypatch):
    def failed(_):
        raise RuntimeError("Ollama isn't running")
    monkeypatch.setattr(backend, "_ai_json", failed)
    job = backend.Job(id="failed_refine", url="https://vimeo.com/123", language="auto", status="completed",
                      duration=4, segments=[{"start": 0, "end": 3, "text": "Keep the original."}])
    backend.refine_video(job)
    assert job.refine_status == "failed"
    assert job.segments[0]["text"] == "Keep the original."
    assert not job.cleaned_text


def test_refinement_endpoint(monkeypatch):
    class FakeThread:
        def __init__(self, target, args, daemon): pass
        def start(self): pass
    monkeypatch.setattr(backend.threading, "Thread", FakeThread)
    job = backend.Job(id="refinable", url="https://vimeo.com/123", language="auto", status="completed",
                      duration=8, segments=[{"start": 0, "end": 7, "text": "A completed video"}])
    backend._jobs[job.id] = job
    try:
        response = client.post("/api/jobs/refinable/refine")
        assert response.status_code == 202
        assert response.json()["refine_status"] == "processing"
        assert client.post("/api/jobs/refinable/refine").status_code == 409
    finally:
        backend._jobs.pop(job.id)


def test_trailing_dot_hostname_is_normalized_not_500(monkeypatch):
    class FakeThread:
        def __init__(self, target, args, daemon): pass
        def start(self): pass
    monkeypatch.setattr(backend.threading, "Thread", FakeThread)
    assert backend.validate_video_url("https://www.youtube.com./watch?v=abc") == "https://www.youtube.com/watch?v=abc"
    response = client.post("/api/jobs", json={"url": "https://www.YouTube.com./watch?v=abc", "language": "auto"})
    assert response.status_code == 202
    job_id = response.json()["job_id"]
    assert client.get(f"/api/jobs/{job_id}").json()["platform"] == "YouTube"
    backend._jobs.pop(job_id)


def test_capabilities_endpoint_reports_provider(monkeypatch):
    monkeypatch.setattr(backend, "AI_PROVIDER", "openai")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    data = client.get("/api/capabilities").json()
    assert data["ai_provider"] == "none" and data["ai_sends_transcript_offsite"] is False
    monkeypatch.setenv("OPENAI_API_KEY", "x")
    data = client.get("/api/capabilities").json()
    assert data["ai_provider"] == "openai" and data["ai_sends_transcript_offsite"] is True
    assert set(data) >= {"ffmpeg", "whisper_model", "max_video_minutes"}


def test_refine_errors_are_public(monkeypatch):
    import httpx as _httpx
    request = _httpx.Request("POST", "https://api.openai.com/v1/chat/completions")
    error = _httpx.HTTPStatusError("boom", request=request, response=_httpx.Response(401, request=request))
    assert backend._public_refine_error(error) == "The AI service returned an error (401)."
    assert "api.openai.com" not in backend._public_refine_error(error)
    assert backend._public_refine_error(RuntimeError("Ollama isn't running.")) == "Ollama isn't running."
