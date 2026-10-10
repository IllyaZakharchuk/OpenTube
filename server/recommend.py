"""
OpenTube recommendations for the Oracle box.

Wire these routes into the same process that already serves
/api/search and /api/audio/stream. Both FastAPI and Flask apps are
supported (auto-detected) — the live Oracle server is FastAPI.

    pip install ytmusicapi requests
    export LASTFM_API_KEY=your_key   # optional but better similar-tracks

    from recommend import register_recommend_routes
    register_recommend_routes(app)   # app = FastAPI() or Flask()
"""

from __future__ import annotations

import functools
import os
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Callable, TypeVar

import requests

try:
    from ytmusicapi import YTMusic
except ImportError:  # pragma: no cover
    YTMusic = None

# `Request` must live at MODULE scope: because of `from __future__ import
# annotations` (above), FastAPI resolves handler type hints like
# `request: Request` from the module globals. A function-local import would
# leave the annotation unresolved and FastAPI would misinterpret `request`
# as a required query parameter (HTTP 422). Flask-only deploys never need it.
try:
    from fastapi import Request  # noqa: F401  (used in FastAPI route hints)
except Exception:  # pragma: no cover
    try:
        from starlette.requests import Request  # type: ignore # noqa: F401
    except Exception:
        Request = None

LASTFM_API_KEY = os.environ.get("LASTFM_API_KEY", "")
_yt = None
_radio_cache: dict[str, tuple[float, list[dict]]] = {}
CACHE_TTL = 6 * 60 * 60

# ---------------------------------------------------------------------------
# Perf: shared thread pool + TTL caches.
#
# NOTE on "asyncio.gather": this module is wired into a *synchronous* Flask
# app (see register_recommend_routes), so awaiting coroutines inside a
# request handler is not possible without a separate async server. True
# wall-clock parallelism is achieved with a shared ThreadPoolExecutor —
# ytmusicapi/Last.fm/Deezer calls are I/O-bound (network wait), which is
# exactly what threads parallelize well under CPython. The public helpers
# below keep their sync signatures, so Flask handlers and existing callers
# are untouched.
# ---------------------------------------------------------------------------

# Threads for parallel fan-out of per-seed / multi-source lookups.
_POOL = ThreadPoolExecutor(max_workers=12, thread_name_prefix="opentube-rec")

# Generic TTL cache: key -> (expires_at, value). Guarded by a lock because
# Flask serves requests from multiple threads.
_TTL_STORE: dict[str, tuple[float, Any]] = {}
_TTL_LOCK = threading.Lock()
SEARCH_TTL = 8 * 60  # search results / import metadata: 8 min
RECOMMEND_TTL = 6 * 60  # assembled recommendations: 6 min

T = TypeVar("T")


def _ttl_get(key: str) -> Any | None:
    now = time.time()
    with _TTL_LOCK:
        hit = _TTL_STORE.get(key)
        if hit is None:
            return None
        expires_at, value = hit
        if expires_at < now:
            _TTL_STORE.pop(key, None)
            return None
        return value


def _ttl_set(key: str, value: Any, ttl: float) -> None:
    with _TTL_LOCK:
        # Tiny opportunistic eviction so the dict cannot grow unbounded.
        if len(_TTL_STORE) > 2000:
            now = time.time()
            dead = [k for k, (exp, _) in _TTL_STORE.items() if exp < now]
            for k in dead:
                _TTL_STORE.pop(k, None)
        _TTL_STORE[key] = (time.time() + ttl, value)


def ttl_cache(ttl: float, key_fn: Callable[..., str]):
    """Decorator: cache function results for `ttl` seconds.

    Failures are never cached — a timed-out seed must not poison later
    requests. Cache lives in-process (per Flask worker).
    """

    def deco(fn: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> T:
            try:
                key = key_fn(*args, **kwargs)
            except Exception:
                return fn(*args, **kwargs)
            hit = _ttl_get(key)
            if hit is not None:
                return hit
            value = fn(*args, **kwargs)
            _ttl_set(key, value, ttl)
            return value

        return wrapper

    return deco


def _gather(
    tasks: list[tuple[str, Callable[[], T]]],
    timeout: float | None = None,
) -> dict[str, T | None]:
    """Run blocking callables concurrently, like asyncio.gather with
    return_exceptions=True: one slow/failing seed never blocks or crashes
    the rest — its slot is simply None and the caller falls back."""
    out: dict[str, T | None] = {}
    if not tasks:
        return out
    futures = { _POOL.submit(fn): name for name, fn in tasks }
    try:
        for fut in as_completed(futures, timeout=timeout):
            name = futures[fut]
            try:
                out[name] = fut.result()
            except Exception:
                out[name] = None
    except Exception:
        # as_completed timeout itself — collect whatever finished.
        pass
    for name, _ in tasks:
        out.setdefault(name, None)
    return out


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
    artist = ""
    if artists:
        artist = artists[0].get("name") or ""
    if not artist:
        # Unofficial/underground uploads often expose the channel only via
        # author/uploader/byline — never drop the track for that.
        for key in ("author", "uploader", "byline"):
            val = item.get(key)
            if isinstance(val, str) and val.strip():
                artist = val.strip()
                break
            if isinstance(val, list) and val:
                first = val[0]
                name = first.get("name") if isinstance(first, dict) else first
                if isinstance(name, str) and name.strip():
                    artist = name.strip()
                    break
    thumbs = item.get("thumbnails") or []
    return {
        "id": vid,
        "title": item.get("title") or "",
        "uploader": artist,
        "artist": artist,
        "thumbnail": thumbs[-1]["url"] if thumbs else None,
    }


def radio_for(video_id: str, limit: int = 20) -> list[dict]:
    """Watch-playlist radio with TTL cache (failures are never cached)."""
    now = time.time()
    cached = _radio_cache.get(video_id)
    if cached and now - cached[0] < CACHE_TTL:
        return cached[1][:limit]
    try:
        watch = _ytmusic().get_watch_playlist(videoId=video_id, limit=limit + 4)
    except Exception:
        return list(cached[1][:limit]) if cached else []
    tracks = []
    for item in watch.get("tracks") or []:
        parsed = _track_from_yt(item)
        if parsed and parsed["id"] != video_id:
            tracks.append(parsed)
        if len(tracks) >= limit:
            break
    _radio_cache[video_id] = (now, tracks)
    return tracks


@ttl_cache(SEARCH_TTL, lambda artist, title="", limit=10: f"lfm_tr:{artist.strip().lower()}|{title.strip().lower()}|{limit}")
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


@ttl_cache(SEARCH_TTL, lambda artist, title="", limit=5: f"dz:{artist.strip().lower()}|{title.strip().lower()}|{limit}")
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


@ttl_cache(SEARCH_TTL, lambda query, limit=5: f"ytq:{(query or chr(32)).strip().lower()}|{limit}")
def yt_search(query: str, limit: int = 5) -> list[dict]:
    """Search YouTube Music without dropping underground/unofficial tracks.

    No keyword/duration filtering here on purpose: Lil Peep-type mixtape
    cuts, unofficial uploads and short tracks are valid results. We try the
    unfiltered search first (it surfaces unofficial uploads), then fall back
    to filter="songs", and over-fetch slightly so per-seed queries still
    return enough candidates.
    """
    query = (query or "").strip()
    if not query:
        return []
    fetch_n = min(max(limit * 2, limit + 4), 25)
    try:
        ytm = _ytmusic()
    except Exception:
        return []
    out: list[dict] = []
    seen: set[str] = set()
    for kwargs in ({"limit": fetch_n}, {"filter": "songs", "limit": fetch_n}):
        try:
            results = ytm.search(query, **kwargs) or []  # type: ignore[arg-type]
        except Exception:
            continue
        for item in results:
            parsed = _track_from_yt(item)
            if parsed and parsed["id"] not in seen:
                seen.add(parsed["id"])
                out.append(parsed)
            if len(out) >= limit:
                return out
    return out


def build_recommendations(payload: dict[str, Any]) -> list[dict]:
    seeds = payload.get("seeds") or []
    exclude = set(payload.get("exclude_ids") or [])
    try:
        limit = int(payload.get("limit") or 20)
    except (TypeError, ValueError):
        limit = 20
    limit = min(max(limit, 1), 100)
    for seed in seeds:
        sid = seed.get("id")
        if sid:
            exclude.add(sid)

    votes: dict[str, dict] = {}
    votes_lock = threading.Lock()

    def add(track: dict, weight: float, discovery: bool, seed_id: str) -> None:
        tid = track.get("id")
        if not tid or tid in exclude:
            return
        with votes_lock:
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

    def process_seed(seed: dict) -> None:
        """All lookups for ONE seed — runs in the shared pool.

        Any single lookup may fail/time out; exceptions are swallowed here
        so one bad seed never blocks or crashes the whole response —
        partial results still rank below.
        """
        try:
            vid = seed.get("id") or ""
            seed_id = vid or f"{seed.get('artist')}|{seed.get('title')}"
            weight = float(seed.get("score") or 1)
            artist = (seed.get("artist") or "").strip()
            title = (seed.get("title") or "").strip()

            # Fan out this seed's independent sources concurrently
            # (radio + last.fm similars + direct metadata queries).
            inner: list[tuple[str, Callable[[], Any]]] = []
            if vid:
                inner.append((f"{seed_id}|radio", lambda: radio_for(vid, 16)))
            inner.append(
                (f"{seed_id}|lfm", lambda: lastfm_similar(artist, title, 8))
            )
            seed_queries: list[str] = []
            if artist and title:
                seed_queries.append(f"{artist} {title}")
            if artist:
                seed_queries.append(artist)
            if title and title.lower() not in artist.lower():
                seed_queries.append(title)
            for q in seed_queries:
                inner.append(
                    (f"{seed_id}|q:{q}", (lambda qq: lambda: yt_search(qq, 4))(q))
                )
            got = _gather(inner, timeout=25)

            for t in got.get(f"{seed_id}|radio") or []:
                if isinstance(t, dict):
                    add(t, weight, discovery=False, seed_id=seed_id)
            for sim in got.get(f"{seed_id}|lfm") or []:
                if not isinstance(sim, dict):
                    continue
                try:
                    for t in yt_search(
                        f"{sim.get('artist')} {sim.get('title')}", limit=2
                    ):
                        add(t, weight * 0.85, discovery=False, seed_id=seed_id)
                except Exception:
                    continue
            # Direct per-seed metadata search: this is what keeps underground /
            # unofficial tracks (Lil Peep etc.) in the mix. Never merge seeds
            # into one combined "artist1 artist2 ..." query — YouTube then
            # returns only the dominant (mainstream) artist.
            for q in seed_queries:
                for t in got.get(f"{seed_id}|q:{q}") or []:
                    if isinstance(t, dict):
                        add(t, weight * 1.5, discovery=False, seed_id=seed_id)
        except Exception:
            return

    # Parallelize across seeds (12 core) — sequential here meant
    # 12 x (radio + last.fm + N x yt_search) blocking round-trips.
    core_tasks = [
        (f"seed:{i}", (lambda s: lambda: process_seed(s))(seed))
        for i, seed in enumerate(ranked_seeds[:12])
    ]
    _gather(core_tasks, timeout=40)

    def process_discovery(seed: dict) -> None:
        try:
            vid = seed.get("id") or ""
            seed_id = vid or f"{seed.get('artist')}|{seed.get('title')}"
            weight = float(seed.get("score") or 1) * 0.45
            names = lastfm_similar_artists(seed.get("artist") or "", 4)
            if not names:
                names = deezer_related_artists(
                    seed.get("artist") or "", seed.get("title") or "", 4
                )
            inner: list[tuple[str, Callable[[], Any]]] = [
                (f"{seed_id}|rel:{n}", (lambda nn: lambda: yt_search(nn, 3))(n))
                for n in names
            ]
            got = _gather(inner, timeout=25)
            for n in names:
                for t in got.get(f"{seed_id}|rel:{n}") or []:
                    if isinstance(t, dict):
                        add(t, weight, discovery=True, seed_id=seed_id)
        except Exception:
            return

    disc_tasks = [
        (f"disc:{i}", (lambda s: lambda: process_discovery(s))(seed))
        for i, seed in enumerate(ranked_seeds[:8])
    ]
    _gather(disc_tasks, timeout=40)

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


def _recommend_cache_key(payload: dict[str, Any]) -> str:
    try:
        seeds = payload.get("seeds") or []
        parts = []
        for s in seeds:
            parts.append(
                f"{s.get('id')}|{s.get('artist')}|{s.get('title')}|{s.get('score')}"
            )
        excl = sorted(payload.get("exclude_ids") or [])
        return f"rec:{'|'.join(sorted(parts))}#{'|'.join(excl)}#{payload.get('limit')}"
    except Exception:
        return f"rec:{time.time_ns()}"


def build_recommendations_cached(payload: dict[str, Any]) -> list[dict]:
    """TTL-cached entry point used by the /api/recommend handler."""
    key = _recommend_cache_key(payload)
    hit = _ttl_get(key)
    if hit is not None:
        return [dict(t) for t in hit]
    out = build_recommendations(payload)
    _ttl_set(key, out, RECOMMEND_TTL)
    return out


@ttl_cache(SEARCH_TTL, lambda playlist_id, limit=200: f"pl:{(playlist_id or chr(32)).strip()}|{limit}")
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


def _is_fastapi_app(app) -> bool:
    """Detect a FastAPI/Starlette app vs a Flask app.

    The live OpenTube server on the Oracle box is FastAPI (it serves
    /openapi.json and returns FastAPI-style {"detail": "Not Found"} 404s),
    while some self-hosted deployments still run Flask. We support both.
    """
    try:
        module = (type(app).__module__ or "").lower()
    except Exception:
        module = ""
    if "fastapi" in module or "starlette" in module:
        return True
    if "flask" in module:
        return False
    # Heuristic fallback: FastAPI/Starlette expose an OpenAPI schema method
    # and a router; Flask exposes neither.
    return hasattr(app, "openapi") and hasattr(app, "router")


def _as_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def register_recommend_routes(app) -> None:
    """Attach /api/radio, /api/recommend and /api/import/youtube/playlist.

    Works with BOTH FastAPI and Flask apps (auto-detected). This fixes the
    "404 Not Found on /api/recommend" bug: the handlers were previously
    Flask-only (@app.get + jsonify + request.args) and therefore never
    registered on the FastAPI server that actually serves the app.

    Every endpoint is exception-safe: a failing seed or a timing-out
    upstream call (ytmusicapi / Last.fm / Deezer) yields a valid JSON body
    with partial results instead of crashing or aborting the connection.
    """
    if _is_fastapi_app(app):
        _register_fastapi_routes(app)
    else:
        _register_flask_routes(app)


def _register_flask_routes(app) -> None:
    """Flask implementation (unchanged behaviour, kept for self-hosted use)."""

    @app.get("/api/radio")
    def api_radio():
        from flask import jsonify, request

        video_id = (request.args.get("id") or "").strip()
        limit = _as_int(request.args.get("limit"), 15)
        offset = max(_as_int(request.args.get("offset"), 0), 0)
        if not video_id:
            return jsonify({"results": []})
        try:
            tracks = radio_for(video_id, offset + limit)
            return jsonify({"results": tracks[offset : offset + limit]})
        except Exception as exc:
            return jsonify({"results": [], "error": str(exc)}), 502

    @app.post("/api/recommend")
    def api_recommend():
        from flask import jsonify, request

        payload = request.get_json(silent=True) or {}
        if not isinstance(payload, dict):
            payload = {}
        try:
            # TTL-cached + parallelized: repeat requests return in ms,
            # first builds fan out across seeds concurrently.
            return jsonify({"results": build_recommendations_cached(payload)})
        except Exception as exc:
            return jsonify({"results": [], "error": str(exc)}), 502

    @app.get("/api/import/youtube/playlist")
    def api_import_youtube_playlist():
        """Parse a YouTube / YouTube Music playlist into importable tracks.

        Query params: `playlist_id` (or `url` with `list=...`), `limit`,
        `offset` (batch paging; 0-based slice into the resolved track list).
        Returns a plain JSON list so older Flutter clients keep working.
        """
        from flask import jsonify, request

        params = request.args
        raw_id = (params.get("playlist_id") or "").strip()
        raw_url = (params.get("url") or "").strip()
        if not raw_id and raw_url:
            try:
                from urllib.parse import parse_qs, urlparse

                raw_id = (parse_qs(urlparse(raw_url).query).get("list") or [""])[0].strip()
            except Exception:
                raw_id = ""
        limit = min(max(_as_int(params.get("limit"), 200), 1), 500)
        offset = max(_as_int(params.get("offset"), 0), 0)
        if not raw_id:
            return jsonify({"error": "playlist_id (or url with list=) is required"}), 400
        try:
            tracks = playlist_tracks(raw_id, offset + limit)
            return jsonify(tracks[offset : offset + limit])
        except Exception as exc:
            return jsonify({"error": str(exc)}), 502


def _register_fastapi_routes(app) -> None:
    """FastAPI implementation — the one the live Oracle server needs.

    Handlers are ``async def`` and offload the blocking, network-heavy work
    (ytmusicapi fan-out via the shared ThreadPoolExecutor) to a worker
    thread with ``run_in_threadpool`` so the ASGI event loop never stalls.
    Query params come from ``request.query_params``; the recommend body is
    read with ``await request.json()``. Any failure returns a JSONResponse
    carrying partial results instead of raising/aborting the connection.
    """
    try:
        from fastapi import Request
        from fastapi.responses import JSONResponse
        from fastapi.concurrency import run_in_threadpool
    except Exception:  # pragma: no cover - fall back to raw starlette
        from starlette.requests import Request  # type: ignore
        from starlette.responses import JSONResponse  # type: ignore
        from starlette.concurrency import run_in_threadpool  # type: ignore

    def _err(status: int, message: Any):
        return JSONResponse(status_code=status, content={"error": str(message)})

    @app.get("/api/radio")
    async def api_radio(request: Request):
        params = request.query_params
        video_id = (params.get("id") or "").strip()
        limit = _as_int(params.get("limit"), 15)
        offset = max(_as_int(params.get("offset"), 0), 0)
        if not video_id:
            return {"results": []}
        try:
            tracks = await run_in_threadpool(radio_for, video_id, offset + limit)
            return {"results": tracks[offset : offset + limit]}
        except Exception as exc:
            return JSONResponse(
                status_code=502, content={"results": [], "error": str(exc)}
            )

    @app.post("/api/recommend")
    async def api_recommend(request: Request):
        try:
            payload = await request.json()
        except Exception:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        try:
            results = await run_in_threadpool(build_recommendations_cached, payload)
            return {"results": results}
        except Exception as exc:
            return JSONResponse(
                status_code=502, content={"results": [], "error": str(exc)}
            )

    @app.get("/api/import/youtube/playlist")
    async def api_import_youtube_playlist(request: Request):
        """Parse a YouTube / YouTube Music playlist into importable tracks.

        Query params: `playlist_id` (or `url` with `list=...`), `limit`,
        `offset` (batch paging; 0-based slice into the resolved track list).
        Returns a plain JSON list so older Flutter clients keep working.
        """
        params = request.query_params
        raw_id = (params.get("playlist_id") or "").strip()
        raw_url = (params.get("url") or "").strip()
        if not raw_id and raw_url:
            try:
                from urllib.parse import parse_qs, urlparse

                raw_id = (parse_qs(urlparse(raw_url).query).get("list") or [""])[0].strip()
            except Exception:
                raw_id = ""
        limit = min(max(_as_int(params.get("limit"), 200), 1), 500)
        offset = max(_as_int(params.get("offset"), 0), 0)
        if not raw_id:
            return _err(400, "playlist_id (or url with list=) is required")
        try:
            tracks = await run_in_threadpool(playlist_tracks, raw_id, offset + limit)
            return tracks[offset : offset + limit]
        except Exception as exc:
            return _err(502, exc)
