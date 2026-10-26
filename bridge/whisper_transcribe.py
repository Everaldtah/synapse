#!/usr/bin/env python3
"""Synapse Bridge helper: transcribe one audio/video file with OpenAI Whisper and stream the result.

    python whisper_transcribe.py <file> [--model large-v3-turbo] [--language en] [--device cuda|cpu]

Prints one JSON object per line on stdout, flushed as soon as it is known:
    {"type":"info","duration":12.3,"model":"large-v3-turbo","device":"cuda","language":"en"}
    {"type":"segment","start":0.0,"end":4.2,"text":"..."}            (one per segment, while decoding)
    {"type":"done"}            or            {"type":"error","message":"..."}
Everything else (warnings, progress) goes to stderr.

openai-whisper has no per-segment callback. With verbose=True it prints "[mm:ss.mmm --> mm:ss.mmm] text" for every
segment the moment its 30-second window is decoded, so we catch those prints (stdout is redirected to a parser while
transcribe() runs) and turn each one into a JSON line.
"""

import argparse
import contextlib
import io
import json
import re
import sys

# The real stdout carries our JSON; force UTF-8 and a flush per line whatever the console code page is.
OUT = sys.stdout
try:
    OUT.reconfigure(encoding="utf-8", line_buffering=True)
except Exception:  # pragma: no cover - very old Pythons
    pass


def emit(obj):
    OUT.write(json.dumps(obj, ensure_ascii=False) + "\n")
    OUT.flush()


SEGMENT_RE = re.compile(r"^\[(?:(\d+):)?(\d+):(\d+(?:\.\d+)?) --> (?:(\d+):)?(\d+):(\d+(?:\.\d+)?)\]\s?(.*)$")


def seconds(h, m, s):
    return round(int(h or 0) * 3600 + int(m) * 60 + float(s), 3)


class SegmentSink(io.TextIOBase):
    """Stands in for sys.stdout during transcribe(): segment lines become JSON, anything else goes to stderr."""

    def __init__(self):
        self.buf = ""

    def writable(self):
        return True

    def write(self, s):
        self.buf += s
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            self.handle(line)
        return len(s)

    def flush(self):
        pass

    def close_out(self):
        if self.buf:
            self.handle(self.buf)
            self.buf = ""

    def handle(self, line):
        m = SEGMENT_RE.match(line.rstrip("\r"))
        if not m:
            if line.strip():
                print(line, file=sys.stderr, flush=True)
            return
        text = m.group(7).strip()
        start, end = seconds(*m.group(1, 2, 3)), seconds(*m.group(4, 5, 6))
        # whisper prints empty or zero-length segments too, and drops them afterwards.
        if text and end > start:
            emit({"type": "segment", "start": start, "end": end, "text": text})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--model", default="large-v3-turbo")
    ap.add_argument("--language", default=None, help="2-letter code; omit to auto-detect")
    ap.add_argument("--device", default=None, help="cuda or cpu (default: cuda when available)")
    args = ap.parse_args()

    try:
        import torch
        import whisper
        from whisper.tokenizer import LANGUAGES
    except Exception as e:
        emit({"type": "error", "message": f"Whisper is not installed for this Python ({sys.executable}): {e}. Run: pip install openai-whisper"})
        return 1

    try:
        # Decode once (ffmpeg, 16 kHz mono) and hand the samples to transcribe() so it doesn't decode again.
        audio = whisper.load_audio(args.file)
    except Exception as e:
        emit({"type": "error", "message": f"Could not read the audio (is ffmpeg installed?): {str(e).strip()[-400:]}"})
        return 1
    duration = round(len(audio) / whisper.audio.SAMPLE_RATE, 3)
    if duration <= 0:
        emit({"type": "error", "message": "The file contains no audio."})
        return 1

    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    try:
        model = whisper.load_model(args.model, device=device)
    except Exception as e:
        if device != "cuda":
            emit({"type": "error", "message": f"Could not load Whisper model {args.model}: {e}"})
            return 1
        # Usually out of GPU memory (a game is running): CPU is slower but still works.
        print(f"CUDA load failed ({e}); falling back to CPU", file=sys.stderr, flush=True)
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        device = "cpu"
        model = whisper.load_model(args.model, device=device)
    fp16 = device == "cuda"

    language = (args.language or "").lower() or None
    if language and language not in LANGUAGES:
        print(f"Unknown language '{language}', auto-detecting", file=sys.stderr, flush=True)
        language = None
    if language is None:
        if model.is_multilingual:
            # Same as whisper's own detection: the first 30 seconds.
            mel = whisper.log_mel_spectrogram(whisper.pad_or_trim(audio), model.dims.n_mels).to(model.device)
            _, probs = model.detect_language(mel.half() if fp16 else mel)
            language = max(probs, key=probs.get)
        else:
            language = "en"

    emit({"type": "info", "duration": duration, "model": args.model, "device": device, "language": language})

    sink = SegmentSink()
    try:
        with contextlib.redirect_stdout(sink):
            model.transcribe(audio, language=language, fp16=fp16, verbose=True)
        sink.close_out()
    except Exception as e:
        sink.close_out()
        emit({"type": "error", "message": f"Transcription failed: {e}"})
        return 1

    emit({"type": "done"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
