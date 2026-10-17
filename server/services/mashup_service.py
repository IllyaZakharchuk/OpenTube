"""DJ mashup service: vocals of one track + instrumental of another."""

from __future__ import annotations

import asyncio
import os
import shutil
import uuid
from pathlib import Path
from typing import Optional

import librosa
import numpy as np
import soundfile as sf
from pydub import AudioSegment

# Directory where final mashup MP3s and intermediate work files live.
MASHUP_CACHE_DIR = Path(os.environ.get("MASHUP_CACHE_DIR", "/tmp/opentube_mashups"))
MASHUP_CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Demucs model to use for stem separation.
DEMUCS_MODEL = "htdemucs"


class MashupError(Exception):
    """Raised when mashup processing fails at any stage."""


class MashupService:
    """Build a DJ mashup: vocals from track 1 + instrumental from track 2.

    The pipeline is:

    1. Resolve both tracks to local WAV files (download from YouTube if only a
       track id is given).
    2. Run Demucs (``--two-stems=vocals``) on each track to extract vocals from
       track 1 and the no-vocals instrumental from track 2.
    3. Detect BPM of both stems via ``librosa.beat.beat_track`` and time-stretch
       the vocal stem to match the instrumental tempo without changing pitch
       (``librosa.effects.time_stretch``).
    4. Mix the stretched vocals over the instrumental with ``pydub`` and export
       the result to MP3.
    5. Remove every intermediate WAV; only the final MP3 remains.
    """

    def __init__(self, cache_dir: Optional[Path | str] = None) -> None:
        self.cache_dir = Path(cache_dir) if cache_dir else MASHUP_CACHE_DIR
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------ #
    # Public API
    # ------------------------------------------------------------------ #

    async def create_mashup(
        self,
        track_id_1: str,
        track_id_2: str,
        output_name: Optional[str] = None,
    ) -> Path:
        """Create a mashup and return the path to the final MP3.

        :param track_id_1: YouTube id (or existing local path) of the track
            whose vocals will be used.
        :param track_id_2: YouTube id (or existing local path) of the track
            whose instrumental will be used.
        :param output_name: optional filename for the resulting MP3.
        :raises MashupError: if any stage of the pipeline fails.
        """
        temp_files: list[Path] = []
        try:
            # 1. Resolve source audio to local WAV files.
            path_1 = await self._resolve_audio(track_id_1, "track_1")
            path_2 = await self._resolve_audio(track_id_2, "track_2")
            temp_files.extend([path_1, path_2])

            # 2. Stem separation with Demucs (--two-stems=vocals).
            vocals_1, instrumental_2 = await self._extract_stems(
                path_1, path_2, temp_files
            )

            # 3. Tempo sync: detect BPM and time-stretch vocals to match.
            # Run CPU-heavy librosa work off the event loop.
            bpm_1 = await asyncio.to_thread(self._detect_bpm, vocals_1)
            bpm_2 = await asyncio.to_thread(self._detect_bpm, instrumental_2)
            stretched_vocals = await asyncio.to_thread(
                self._time_stretch_to_bpm,
                vocals_1, bpm_1, bpm_2, "vocals_stretched",
            )
            temp_files.append(stretched_vocals)

            # 4. Mix and export MP3.
            output_path = self.cache_dir / (
                output_name or f"mashup_{uuid.uuid4().hex}.mp3"
            )
            await asyncio.to_thread(
                self._mix_to_mp3,
                stretched_vocals, instrumental_2, output_path,
            )

            return output_path
        finally:
            # 5. Cleanup: remove every intermediate WAV, keep only the MP3.
            for temp in temp_files:
                self._safe_remove(temp)

    # ------------------------------------------------------------------ #
    # Internal: audio resolution
    # ------------------------------------------------------------------ #

    async def _resolve_audio(self, track_id: str, tag: str) -> Path:
        """Return a local WAV path for ``track_id`` (file or YouTube id)."""
        candidate = Path(track_id)
        if candidate.exists() and candidate.is_file():
            return candidate

        out_path = self.cache_dir / f"{tag}_{track_id}.wav"
        # Strip any existing suffix so yt-dlp names the file exactly out_path.
        out_stem = out_path.with_suffix("")
        cmd = [
            "yt-dlp",
            "--quiet",
            "--no-warnings",
            "-x",
            "--audio-format", "wav",
            "--audio-quality", "0",
            "-o", str(out_stem),
            f"https://www.youtube.com/watch?v={track_id}",
        ]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await asyncio.wait_for(proc.communicate(), timeout=600)
        if proc.returncode != 0 or not out_path.exists():
            detail = stderr.decode(errors="replace").strip()[:300]
            raise MashupError(f"Failed to download audio for {track_id}: {detail}")
        return out_path

    # ------------------------------------------------------------------ #
    # Internal: stem separation (Demucs)
    # ------------------------------------------------------------------ #

    async def _extract_stems(
        self,
        path_1: Path,
        path_2: Path,
        temp_files: list[Path],
    ) -> tuple[Path, Path]:
        """Run Demucs on both tracks; return (vocals_1, instrumental_2)."""
        work_dir = self.cache_dir / f"demucs_{uuid.uuid4().hex}"
        work_dir.mkdir(parents=True, exist_ok=True)
        temp_files.append(work_dir)

        try:
            vocals_1 = await self._separate_two_stems(path_1, work_dir, "track_1")
            instrumental_2 = await self._separate_two_stems(
                path_2, work_dir, "track_2"
            )
            return vocals_1, instrumental_2
        except Exception:
            shutil.rmtree(work_dir, ignore_errors=True)
            raise

    async def _separate_two_stems(
        self, input_path: Path, work_dir: Path, tag: str
    ) -> Path:
        """Run ``demucs --two-stems=vocals`` and return the requested stem."""
        cmd = [
            "demucs",
            "--two-stems=vocals",
            "--model", DEMUCS_MODEL,
            "-o", str(work_dir),
            "--filename", "{track}/{stem}.{ext}",
            str(input_path),
        ]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await asyncio.wait_for(proc.communicate(), timeout=900)
        if proc.returncode != 0:
            detail = stderr.decode(errors="replace").strip()[:300]
            raise MashupError(f"Demucs failed for {input_path.name}: {detail}")

        # Demucs lays out output as: <out>/<model>/<track without ext>/{vocals,no_vocals}.wav
        track_stem = input_path.stem
        separated_dir = work_dir / DEMUCS_MODEL / track_stem

        # Pick the stem we need based on the tag.
        if tag == "track_1":
            stem_path = separated_dir / "vocals.wav"
        else:
            stem_path = separated_dir / "no_vocals.wav"

        if not stem_path.exists():
            raise MashupError(
                f"Expected stem {stem_path} not produced by Demucs for {input_path.name}"
            )
        return stem_path

    # ------------------------------------------------------------------ #
    # Internal: tempo detection & time-stretch (librosa)
    # ------------------------------------------------------------------ #

    def _detect_bpm(self, audio_path: Path) -> float:
        """Estimate the tempo (BPM) of an audio file via librosa."""
        y, sr = librosa.load(str(audio_path), sr=None, mono=True)
        if len(y) == 0:
            raise MashupError(f"Empty audio: {audio_path}")
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
        bpm = float(tempo)
        if bpm <= 0 or np.isnan(bpm):
            raise MashupError(f"Could not detect BPM for {audio_path}")
        return bpm

    def _time_stretch_to_bpm(
        self,
        vocal_path: Path,
        source_bpm: float,
        target_bpm: float,
        tag: str,
    ) -> Path:
        """Time-stretch ``vocal_path`` from ``source_bpm`` to ``target_bpm``.

        Pitch is preserved; only duration changes. Returns the path to the new
        WAV file.
        """
        if source_bpm <= 0 or target_bpm <= 0:
            raise MashupError("Invalid BPM values for time-stretch")

        rate = target_bpm / source_bpm
        # Guard against extreme stretch factors that would destroy quality.
        rate = min(max(rate, 0.5), 2.0)

        y, sr = librosa.load(str(vocal_path), sr=None, mono=True)
        y_stretched = librosa.effects.time_stretch(y, rate=rate)

        out_path = self.cache_dir / f"{tag}_{uuid.uuid4().hex}.wav"
        sf.write(str(out_path), y_stretched, sr)
        return out_path

    # ------------------------------------------------------------------ #
    # Internal: mixing & export (pydub)
    # ------------------------------------------------------------------ #

    def _mix_to_mp3(
        self,
        vocal_path: Path,
        instrumental_path: Path,
        output_path: Path,
    ) -> None:
        """Overlay vocals on top of the instrumental and export MP3."""
        vocal = AudioSegment.from_wav(str(vocal_path))
        instrumental = AudioSegment.from_wav(str(instrumental_path))

        # Trim both to the shorter length so they align.
        duration = min(len(vocal), len(instrumental))
        vocal = vocal[:duration]
        instrumental = instrumental[:duration]

        mixed = instrumental.overlay(vocal)
        mixed.export(str(output_path), format="mp3", bitrate="192k")

    # ------------------------------------------------------------------ #
    # Utilities
    # ------------------------------------------------------------------ #

    def _safe_remove(self, path: Path) -> None:
        """Remove a file or directory, ignoring missing-path errors."""
        try:
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        except OSError:
            pass