"""
OpenTube recommendations for the Oracle box.

Wire these routes into the same process that already serves
/api/search and /api/audio/stream (Flask assumed).

    pip install ytmusicapi requests
    export LASTFM_API_KEY=your_key   # optional but better similar-tracks

    from recommend import register_recommend_routes
    register_recommend_routes(app)
"""

from __future__ import annotations

import os
import time
from collections import defaultdict
from typing import Any

import requests

try:
    from ytmusicapi import YTMusic
except ImportError:  # pragma: no cover
    YTMusic = None

LASTFM_API_KEY = os.environ.get("LASTFM_API_KEY", "")
_yt = None
_radio_cache: dict[str, tuple[float, list[dict]]] = {}
CACHE_TTL = 6 * 60 * 60


def _ytmusic():
    global _yt
    if _yt is None:
        if YTMusic is None:
            raise RuntimeError("ytmusicapi is not installed")
        _yt = YTMusic()
    return _yt


def _track_from_yt(item: dict) -> dict | None:
    vid = item.get("videoId")
    if not vid:
        return None
    artists = item.get("artists") or []
    artist = artists[0]["name"] if artists else item.get("author", "")
    thumbs = item.get("thumbnails") or []
    return {
        "id": vid,
        "title": item.get("title") or "",
        "uploader": artist,
        "artist": artist,
        "thumbnail": thumbs[-1]["url"] if thumbs else None,
    }


def radio_for(video_id: str, limit: int = 20) -> list[dict]:
    now = time.time()
    cached = _radio_cache.get(video_id)
    if cached and now - cached[0] < CACHE_TTL:
        return cached[1][:limit]
    watch = _ytmusic().get_watch_playlist(videoId=video_id, limit=limit + 4)
    tracks = []
    for item in watch.get("tracks") or []:
        parsed = _track_from_yt(item)
        if parsed and parsed["id"] != video_id:
            tracks.append(parsed)
        if len(tracks) >= limit:
            break
    _radio_cache[video_id] = (now, tracks)
    return tracks


def lastfm_similar(artist: str, title: str, limit: int = 10) -> list[dict]:
    if not LASTFM_API_KEY or not artist or not title:
        return []
    try:
        res = requests.get(
            "https://ws.audioscrobbler.com/2.0/",
            params={
                "method": "track.getsimilar",
                "artist": artist,
                "track": title,
                "api_key": LASTFM_API_KEY,
                "format": "json",
                "limit": str(limit),
            },
            timeout=10,
        )
        tracks = (((res.json() or {}).get("similartracks") or {}).get("track")) or []
        out = []
        for t in tracks[:limit]:
            name = t.get("name") or ""
            art = (t.get("artist") or {}).get("name") or ""
            if name and art:
                out.append({"artist": art, "title": name})
        return out
    except Exception:
        return []


def lastfm_similar_artists(artist: str, limit: int = 6) -> list[str]:
    if not LASTFM_API_KEY or not artist:
        return []
    try:
        res = requests.get(
            "https://ws.audioscrobbler.com/2.0/",
            params={
                "method": "artist.getsimilar",
                "artist": artist,
                "api_key": LASTFM_API_KEY,
                "format": "json",
                "limit": str(limit),
            },
            timeout=10,
        )
        artists = (((res.json() or {}).get("similarartists") or {}).get("artist")) or []
        return [a.get("name") for a in artists if a.get("name")][:limit]
    except Exception:
        return []


def deezer_related_artists(artist: str, title: str, limit: int = 5) -> list[str]:
    try:
        search = requests.get(
            "https://api.deezer.com/search/track",
            params={"q": f"{artist} {title}"},
            timeout=10,
        ).json()
        data = search.get("data") or []
        if not data:
            return []
        artist_id = ((data[0].get("artist") or {}).get("id"))
        if not artist_id:
            return []
        rel = requests.get(
            f"https://api.deezer.com/artist/{artist_id}/related",
            timeout=10,
        ).json()
        return [a.get("name") for a in (rel.get("data") or []) if a.get("name")][:limit]
    except Exception:
        return []


def yt_search(query: str, limit: int = 5) -> list[dict]:
    try:
        results = _ytmusic().search(query, filter="songs", limit=limit)
        out = []
        for item in results:
            parsed = _track_from_yt(item)
            if parsed:
                out.append(parsed)
            if len(out) >= limit:
                break
        return out
    except Exception:
        return []


def build_recommendations(payload: dict[str, Any]) -> list[dict]:
    seeds = payload.get("seeds") or []
    exclude = set(payload.get("exclude_ids") or [])
    limit = int(payload.get("limit") or 20)
    for seed in seeds:
        sid = seed.get("id")
        if sid:
            exclude.add(sid)

    votes: dict[str, dict] = {}

    def add(track: dict, weight: float, discovery: bool, seed_id: str) -> None:
        tid = track.get("id")
        if not tid or tid in exclude:
            return
        bucket = votes.setdefault(
            tid,
            {
                "track": track,
                "votes": 0.0,
                "seed_count": 0,
                "from": set(),
                "discovery": discovery,
            },
        )
        if seed_id not in bucket["from"]:
            bucket["from"].add(seed_id)
            bucket["seed_count"] += 1
        bucket["votes"] += weight
        if not discovery:
            bucket["discovery"] = False

    ranked_seeds = sorted(seeds, key=lambda s: float(s.get("score") or 0), reverse=True)[:16]

    for seed in ranked_seeds[:12]:
        vid = seed.get("id") or ""
        seed_id = vid or f"{seed.get('artist')}|{seed.get('title')}"
        weight = float(seed.get("score") or 1)
        if vid:
            try:
                for t in radio_for(vid, limit=16):
                    add(t, weight, discovery=False, seed_id=seed_id)
            except Exception:
                pass
        for sim in lastfm_similar(seed.get("artist") or "", seed.get("title") or "", 8):
            for t in yt_search(f"{sim['artist']} {sim['title']}", limit=1):
                add(t, weight * 0.85, discovery=False, seed_id=seed_id)

    for seed in ranked_seeds[:8]:
        vid = seed.get("id") or ""
        seed_id = vid or f"{seed.get('artist')}|{seed.get('title')}"
        weight = float(seed.get("score") or 1) * 0.45
        names = lastfm_similar_artists(seed.get("artist") or "", 4)
        if not names:
            names = deezer_related_artists(
                seed.get("artist") or "", seed.get("title") or "", 4
            )
        for name in names:
            for t in yt_search(name, limit=3):
                add(t, weight, discovery=True, seed_id=seed_id)

    ordered = sorted(
        votes.values(),
        key=lambda x: (x["seed_count"], x["votes"]),
        reverse=True,
    )
    core_n = max(1, int(limit * 0.8))
    core = [x for x in ordered if not x["discovery"]]
    explore = [x for x in ordered if x["discovery"]]
    out: list[dict] = []
    seen: set[str] = set()

    def take(items: list[dict], n: int) -> None:
        for item in items:
            if len(out) >= n:
                return
            tid = item["track"]["id"]
            if tid in seen:
                continue
            seen.add(tid)
            row = dict(item["track"])
            row["discovery"] = item["discovery"]
            out.append(row)

    take(core, core_n)
    take(explore, limit)
    take(ordered, limit)
    return out


def playlist_tracks(playlist_id: str, limit: int = 200) -> list[dict]:
    """Fetch tracks of a YouTube / YouTube Music playlist via ytmusicapi."""
    ytm = _ytmusic()
    try:
        data = ytm.get_playlist(playlistId=playlist_id, limit=min(max(limit, 1), 500))
    except Exception:
        # Some ytmusicapi versions use `playlist_id` instead of `playlistId`.
        data = ytm.get_playlist(playlist_id=playlist_id, limit=min(max(limit, 1), 500))  # type: ignore[call-arg]
    out: list[dict] = []
    for item in data.get("tracks") or []:
        vid = item.get("videoId")
        if not vid:
            continue
        artists = item.get("artists") or []
        artist = (
            artists[0]["name"]
            if artists
            else (item.get("author") or item.get("uploader") or "")
        )
        thumbs = item.get("thumbnails") or []
        out.append(
            {
                "videoId": vid,
                "id": vid,
                "title": item.get("title") or "",
                "artist": artist,
                "uploader": artist,
                "thumbnail": thumbs[-1]["url"] if thumbs else None,
                "playlistId": playlist_id,
                "source": "yt",
            }
        )
        if len(out) >= limit:
            break
    return out


def register_recommend_routes(app) -> None:
    """Attach /api/radio and /api/recommend onto an existing Flask app."""

    @app.get("/api/radio")
    def api_radio():
        from flask import jsonify, request

        video_id = request.args.get("id") or ""
        limit = int(request.args.get("limit") or 15)
        if not video_id:
            return jsonify({"results": []})
        try:
            return jsonify({"results": radio_for(video_id, limit)})
        except Exception as exc:
            return jsonify({"results": [], "error": str(exc)}), 502

    @app.post("/api/recommend")
    def api_recommend():
        from flask import jsonify, request

        payload = request.get_json(silent=True) or {}
        try:
            return jsonify({"results": build_recommendations(payload)})
        except Exception as exc:
            return jsonify({"results": [], "error": str(exc)}), 502

    @app.get("/api/import/youtube/playlist")
    def api_import_youtube_playlist():
        """Parse a YouTube / YouTube Music playlist into importable tracks.

        Query params: `playlist_id` (or `url` with `list=...`), `limit`.
        Returns a plain JSON list so older Flutter clients keep working.
        """
        from flask import jsonify, request

        raw_id = (request.args.get("playlist_id") or "").strip()
        raw_url = (request.args.get("url") or "").strip()
        if not raw_id and raw_url:
            try:
                from urllib.parse import parse_qs, urlparse

                raw_id = (parse_qs(urlparse(raw_url).query).get("list") or [""])[0].strip()
            except Exception:
                raw_id = ""
        try:
            limit = int(request.args.get("limit") or 200)
        except ValueError:
            limit = 200
        if not raw_id:
            return jsonify({"error": "playlist_id (or url with list=) is required"}), 400
        try:
            return jsonify(playlist_tracks(raw_id, limit))
        except Exception as exc:
            return jsonify({"error": str(exc)}), 502
