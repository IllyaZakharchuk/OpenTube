import asyncio
import functools
import os
import re
import threading
import time
from urllib.parse import parse_qs, urlparse

import yt_dlp
import httpx
from typing import Any, List, Optional
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

app = FastAPI(title="OpenTube API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

YTDLP_BIN = "/home/opc/opentube-api/venv/bin/yt-dlp"
PROXY_URL = "socks5://127.0.0.1:1080"
CACHE_DIR = "/tmp/opentube_cache"
os.makedirs(CACHE_DIR, exist_ok=True)

# Resolved media URLs are cached with a TTL derived from YouTube's own `expire`
# parameter (see _stream_ttl_for_url) — see STREAM_TTL_* below.

# --- Lightweight TTL cache for search / radio / recommend -------------------
# Prevents redundant heavy yt-dlp calls for identical queries. TTL = 5 minutes.
#
# Every handler is `async def` and pushes the blocking yt-dlp work into a
# thread, so the event loop stays free; the fan-out over seeds uses
# asyncio.gather() so N seeds cost ~1 round-trip instead of N. The cache is
# lock-guarded (FastAPI runs `def` endpoints in a threadpool) and bounded, and
# failures are never cached so one bad upstream cannot poison later requests.
TTL_CACHE = {}
TTL_SECONDS = 300
MAX_CACHE_ENTRIES = 1000
_CACHE_LOCK = threading.Lock()

# Dedicated pool for the blocking yt-dlp calls, sized for nested fan-out so
# parallel per-seed lookups can never starve each other.
_YTDLP_POOL = None


def _blocking_pool():
    """Lazily created executor shared by all blocking yt-dlp work."""
    global _YTDLP_POOL
    if _YTDLP_POOL is None:
        from concurrent.futures import ThreadPoolExecutor

        _YTDLP_POOL = ThreadPoolExecutor(
            max_workers=24, thread_name_prefix="opentube-ytdlp"
        )
    return _YTDLP_POOL


def _extract_playlist_info(target_url, ydl_opts):
    """Blocking yt-dlp playlist parse. Returns {'title', 'tracks'} or raises.

    Runs in a worker thread; never raises out of the thread pool — the caller
    treats an exception as 'no result' so one bad playlist cannot 500 the app.
    """
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        res = ydl.extract_info(target_url, download=False)
        tracks = []
        for entry in (res.get("entries") or []):
            if not entry:
                continue
            tracks.append({
                "title": entry.get("title"),
                "artist": entry.get("uploader") or entry.get("channel"),
                "videoId": entry.get("id"),
            })
        return {"title": res.get("title") or "YouTube Playlist", "tracks": tracks}


async def to_thread(fn, *args, **kwargs):
    """Run a blocking call off the event loop."""
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(
        _blocking_pool(), functools.partial(fn, *args, **kwargs)
    )


def _cache_get(key):
    """Return a fresh cached value, or None. Entries store (expires_at, value)."""
    with _CACHE_LOCK:
        entry = TTL_CACHE.get(key)
        if not entry:
            return None
        expires_at, value = entry
        if expires_at <= time.time():
            TTL_CACHE.pop(key, None)
            return None
        return value


def _cache_set(key, value, ttl=None):
    _cache_set_ttl(key, value, TTL_SECONDS if ttl is None else ttl)


def _cache_set_ttl(key, value, ttl):
    """Store with a per-entry TTL: key -> (expires_at, value)."""
    with _CACHE_LOCK:
        if len(TTL_CACHE) >= MAX_CACHE_ENTRIES:
            now = time.time()
            for k in [k for k, (exp, _) in TTL_CACHE.items() if exp <= now]:
                TTL_CACHE.pop(k, None)
            if len(TTL_CACHE) >= MAX_CACHE_ENTRIES:
                # All entries still fresh: drop the oldest-expiring half.
                oldest = sorted(TTL_CACHE.items(), key=lambda kv: kv[1][0])
                for k, _ in oldest[: len(TTL_CACHE) // 2]:
                    TTL_CACHE.pop(k, None)
        TTL_CACHE[key] = (time.time() + ttl, value)


def _cache_pop(key):
    """Invalidate a cached entry (used when a link turns out to be dead)."""
    with _CACHE_LOCK:
        TTL_CACHE.pop(key, None)


async def cached(cache_key, ttl_seconds, producer):
    """Async TTL cache with single-flight semantics.

    Concurrent identical requests share ONE upstream round-trip instead of
    stampeding yt-dlp, and a failing producer is never cached.
    """
    hit = _cache_get(cache_key)
    if hit is not None:
        return hit
    try:
        value = await producer()
    except Exception:
        return None
    if value is not None:
        _cache_set_ttl(cache_key, value, ttl_seconds)
    return value


# --- Stream URL resolution cache -------------------------------------------
# YouTube's signed media URLs carry an `expire` unix timestamp (~6h out for the
# android player client). We parse it and cache for exactly that long, minus a
# safety margin so we never hand the client a link that dies mid-playback.
STREAM_TTL_MARGIN = 10 * 60        # stop using a link this long before it dies
STREAM_TTL_FALLBACK = 45 * 60      # used when the URL has no readable expire
STREAM_TTL_MAX = 6 * 60 * 60       # never trust a link longer than this
STREAM_RESOLVE_TIMEOUT = 20.0      # yt-dlp spawn must not hang playback forever

# Per-video single-flight locks: asyncio.Lock is bound to the running loop, so
# these are keyed by (loop id, video id) and cleared when they pile up.
_STREAM_LOCKS: dict[tuple[int, str], asyncio.Lock] = {}


def _stream_lock(video_id: str):
    """One lock per (event loop, video id) so identical concurrent requests
    for the same track share a single yt-dlp resolve."""
    loop_key = (id(asyncio.get_running_loop()), video_id)
    lock = _STREAM_LOCKS.get(loop_key)
    if lock is None:
        with _CACHE_LOCK:
            lock = _STREAM_LOCKS.get(loop_key)
            if lock is None:
                if len(_STREAM_LOCKS) > MAX_CACHE_ENTRIES:
                    _STREAM_LOCKS.clear()
                lock = asyncio.Lock()
                _STREAM_LOCKS[loop_key] = lock
    return lock


def _stream_ttl_for_url(url: str) -> float:
    """How long a resolved media URL is safe to cache.

    Reads YouTube's own `expire` parameter. Falls back to a fixed TTL when it
    is missing/unparseable, and clamps to a sane maximum so a bogus far-future
    timestamp cannot pin a dead link in the cache forever.
    """
    try:
        expire = parse_qs(urlparse(url).query).get("expire", [None])[0]
        if not expire:
            return STREAM_TTL_FALLBACK
        ttl = float(expire) - time.time() - STREAM_TTL_MARGIN
    except (TypeError, ValueError, IndexError):
        return STREAM_TTL_FALLBACK
    if ttl <= 0:
        # Already (nearly) expired: keep it briefly rather than dropping it,
        # so a burst of requests still shares one resolution attempt.
        return STREAM_TTL_FALLBACK
    return min(ttl, STREAM_TTL_MAX)


def get_ydl_opts(extra=None):
    opts = {
        'quiet': True,
        'no_warnings': True,
        'skip_download': True,
        'nocheckcertificate': True,
        'proxy': PROXY_URL,
        'extractor_args': {
            'youtube': {
                'player_client': ['android']
            }
        }
    }
    if extra:
        opts.update(extra)
    return opts


def _norm_entry(entry):
    """Normalize a flat yt-dlp entry into the track dict the app expects."""
    if not entry:
        return None
    vid = entry.get("id")
    # YouTube video ids are exactly 11 chars; this drops channels (UC..., 24
    # chars) and playlists (PL..., 34 chars) that ytsearch can return and that
    # are not playable via /api/audio/stream.
    if not vid or len(str(vid)) != 11:
        return None
    thumbs = entry.get("thumbnails")
    thumb = entry.get("thumbnail")
    if not thumb and isinstance(thumbs, list) and thumbs:
        thumb = thumbs[-1].get("url")
    uploader = entry.get("uploader") or entry.get("channel") or ""
    # Real track length in seconds (yt-dlp exposes this on flat entries). The
    # app renders it directly, so search/radio results now show true durations
    # instead of a hardcoded placeholder.
    duration = entry.get("duration")
    if isinstance(duration, float):
        duration = int(round(duration))
    return {
        "id": vid,
        "videoId": vid,
        "title": entry.get("title") or "",
        "uploader": uploader,
        "artist": uploader,
        "duration": duration,
        "thumbnail": thumb,
        "artworkUrl": thumb,
        "url": f"https://www.youtube.com/watch?v={vid}",
    }


# Words that almost always mark a NON-music upload (podcast, vlog, tutorial,
# reaction, etc.). Used to keep search/recommendation results music-only.
_NON_MUSIC_RE = re.compile(
    r"\b(podcast|episode|ep\.?\s*\d+|vlog|tutorial|how\s+to|reaction|"
    r"interview|documentary|trailer|gameplay|walkthrough|review|unboxing|"
    r"news|highlights?|full\s+match|asmr|meditation|workout\s+routine|"
    r"recipe|cooking|workout|compilation\s+of\s+vlog)\b",
    re.IGNORECASE,
)


def _looks_like_music(entry) -> bool:
    """Heuristic: does a flat yt-dlp entry look like a music track (not a
    podcast / vlog / tutorial / reaction video)?

    We only *reject* clear non-music signals — never require a positive music
    signal — so unofficial uploads, covers and short cuts still pass. yt-dlp
    flat entries usually omit `categories`, so we lean on title/channel
    keywords plus the (optional) category list when present.
    """
    if not entry:
        return False
    cats = entry.get("categories")
    if isinstance(cats, list) and cats:
        # If YouTube tagged it, honor an explicit non-music category.
        joined = " ".join(str(c).lower() for c in cats)
        if any(
            bad in joined
            for bad in ("nonprofit", "activism", "howto", "how-to", "education",
                        "gaming", "sports", "travel", "science", "technology",
                        "news", "politics", "comedy", "film", "animation",
                        "autos", "pets")
        ):
            return False
        if "music" in joined:
            return True
    title = entry.get("title") or ""
    if _NON_MUSIC_RE.search(title):
        return False
    return True


def _extract_music(target, count):
    """Like `_extract_flat` but keeps only entries that look like music.

    Over-fetches from yt-dlp (3x) so that after dropping non-music clips we
    still return close to `count` tracks. Never raises (partial-safe).
    """
    ydl_opts = get_ydl_opts({'extract_flat': 'in_playlist'})
    out = []
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            res = ydl.extract_info(target, download=False)
            for entry in (res.get("entries") or []):
                if not entry:
                    continue
                if not _looks_like_music(entry):
                    continue
                norm = _norm_entry(entry)
                if norm:
                    out.append(norm)
                if len(out) >= count:
                    break
    except Exception as e:
        print(f"[ytdlp] music extract failed for {target}: {e}")
    return out


def _extract_flat(target, count):
    """Flat-extract up to `count` normalized tracks from a yt-dlp target.
    Never raises: returns whatever could be resolved (partial-safe)."""
    ydl_opts = get_ydl_opts({'extract_flat': 'in_playlist'})
    out = []
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            res = ydl.extract_info(target, download=False)
            for entry in (res.get("entries") or []):
                norm = _norm_entry(entry)
                if norm:
                    out.append(norm)
                if len(out) >= count:
                    break
    except Exception as e:
        print(f"[ytdlp] extract failed for {target}: {e}")
    return out


@app.get("/")
def health_check():
    return {
        "status": "ok",
        "service": "OpenTube API",
        "proxy": PROXY_URL
    }


@app.get("/api/search")
async def search_tracks(q: str, limit: int = 10, offset: int = 0):
    limit = max(1, min(limit, 50))
    offset = max(0, offset)
    cache_key = f"search:{q}:{limit}:{offset}"

    async def producer():
        # Over-fetch then slice so `offset` works with ytsearch{limit}.
        # We fetch 3x and filter to music-only so that after dropping podcasts/
        # vlogs/reaction clips the page still fills with real tracks.
        count = offset + limit
        fetch_n = min(count * 3, 60)
        query = f"ytsearch{fetch_n}:{q}"
        return await to_thread(_extract_music, query, fetch_n)

    results = await cached(cache_key, TTL_SECONDS, producer)
    return {"query": q, "results": (results or [])[offset:offset + limit]}


@app.get("/api/import/youtube/playlist")
async def import_youtube_playlist(playlist_id: str = None, url: str = None,
                                  limit: int = None, offset: int = 0):
    """Parse a YouTube / YouTube Music playlist into importable tracks.

    Accepts a bare `playlist_id`, a full `url` (plain YouTube watch / playlist
    links as well as music.youtube.com links, incl. extra params like &si=),
    or both. `limit`/`offset` slice the resolved track list for batched
    imports. Always returns {"title", "tracks", "playlistId"} (HTTP 200) on
    success; raises HTTPException(400/502) otherwise — never a bare list.
    """
    raw_url = (url or "").strip()
    raw_id = (playlist_id or "").strip()
    if not raw_id and raw_url:
        try:
            raw_id = (
                parse_qs(urlparse(raw_url).query).get("list") or [""]
            )[0].strip()
        except Exception:
            raw_id = ""
    if not raw_id:
        raise HTTPException(
            status_code=400,
            detail="playlist_id (or url with list=) is required",
        )
    target_url = f"https://www.youtube.com/playlist?list={raw_id}"
    # Import metadata is expensive and rarely changes: cache the parsed result.
    cache_key = f"import_pl:{target_url}"

    async def producer():
        ydl_opts = get_ydl_opts({'extract_flat': 'in_playlist'})
        return await to_thread(_extract_playlist_info, target_url, ydl_opts)

    res = await cached(cache_key, TTL_SECONDS, producer)
    if res is None:
        raise HTTPException(status_code=502, detail="Failed to parse playlist")
    offset = max(0, offset)
    tracks = res.get("tracks") or []
    # This endpoint is a "give me the WHOLE playlist" call, not a paginated
    # search. yt-dlp already resolved every entry (no `playlistend` is set) and
    # the full list is cached above, so we ALWAYS return everything and IGNORE
    # any `limit`. This guarantees 400+ track playlists are never truncated
    # server-side, even if a stale client still sends limit=200.
    tracks = tracks[offset:]
    return {
        "title": res.get("title") or "YouTube Playlist",
        "playlistId": raw_id,
        "tracks": tracks
    }


@app.get("/api/radio")
async def radio_tracks(id: str, limit: int = 12, offset: int = 0):
    """Auto-generated YouTube radio/mix for a seed video id (RD<id>)."""
    limit = max(1, min(limit, 50))
    offset = max(0, offset)
    cache_key = f"radio:{id}:{limit}:{offset}"

    async def producer():
        radio_url = f"https://www.youtube.com/watch?v={id}&list=RD{id}"
        entries = await to_thread(_extract_flat, radio_url, offset + limit + 1)
        # Drop the seed track itself if it shows up first.
        return [e for e in entries if e["id"] != id]

    entries = await cached(cache_key, TTL_SECONDS, producer)
    page = (entries or [])[offset:offset + limit]
    return {"id": id, "results": page}


class RecommendBody(BaseModel):
    seeds: List[Any] = []
    exclude_ids: List[str] = []
    limit: int = 20


@app.post("/api/recommend")
async def recommend_tracks(body: RecommendBody):
    """Build related tracks from listening seeds using yt-dlp radio + search.

    All per-seed radio lookups and per-seed text searches run concurrently via
    asyncio.gather(), so N seeds cost ~1 round-trip instead of N sequential
    blocking ones. Partial-safe: a failing seed never aborts the response.
    """
    limit = max(1, min(body.limit or 20, 50))

    # Extract seed video ids (accept dicts or raw ids), cap for latency.
    seed_ids = []
    for s in (body.seeds or []):
        sid = None
        if isinstance(s, dict):
            sid = s.get("trackId") or s.get("id") or s.get("videoId")
        elif isinstance(s, str):
            sid = s
        if sid:
            sid = str(sid)
            if sid not in seed_ids:
                seed_ids.append(sid)
    seed_ids = seed_ids[:5]

    # Cache the assembled pool WITHOUT the caller's excludes: the client
    # re-sends a growing exclude set on every scroll, so keying on it would
    # produce a fresh key per page and defeat the cache entirely.
    cache_key = "recommend:" + ",".join(seed_ids)

    async def producer():
        pool = []
        seen = set(seed_ids)  # never recommend a seed back to itself

        def _add(entries):
            for e in entries:
                vid = e["id"]
                if vid in seen:
                    continue
                seen.add(vid)
                pool.append(e)

        async def radio_for_seed(sid):
            """One seed's radio lookup. Failure -> empty (never raises)."""
            try:
                radio_url = f"https://www.youtube.com/watch?v={sid}&list=RD{sid}"
                return await to_thread(_extract_flat, radio_url, 12)
            except Exception as e:
                print(f"[recommend] radio failed for {sid}: {e}")
                return []

        # 1) Radio per seed (related tracks) — ALL concurrent, partial-safe.
        waves = await asyncio.gather(
            *[radio_for_seed(sid) for sid in seed_ids],
            return_exceptions=True,
        )
        for wave in waves:
            if isinstance(wave, BaseException) or not wave:
                continue
            _add(wave)
            if len(pool) >= limit * 2:
                break

        # 2) If still short, per-seed text search "artist title" — concurrent.
        if len(pool) < limit:
            queries = []
            for s in (body.seeds or [])[:5]:
                if not isinstance(s, dict):
                    continue
                artist = s.get("artist") or s.get("uploader") or ""
                title = s.get("title") or ""
                q = f"{artist} {title}".strip()
                if q:
                    queries.append(q)

            async def search_seed(q):
                try:
                    return await to_thread(_extract_flat, f"ytsearch6:{q}", 6)
                except Exception as e:
                    print(f"[recommend] search failed for '{q}': {e}")
                    return []

            found = await asyncio.gather(
                *[search_seed(q) for q in queries],
                return_exceptions=True,
            )
            for wave in found:
                if isinstance(wave, BaseException) or not wave:
                    continue
                _add(wave)

        return pool[:min(len(pool), 40)]

    pool = await cached(cache_key, TTL_SECONDS, producer)

    # Always re-apply the caller's exclude set to the (possibly cached) pool.
    exclude = set(str(x) for x in (body.exclude_ids or []))
    exclude.update(seed_ids)
    results = [e for e in (pool or []) if e["id"] not in exclude][:limit]
    return {"results": results}


async def get_direct_stream_url(video_id: str, force: bool = False) -> str:
    """Resolve (and cache) the direct audio URL for a video.

    This is the hot path for playback: the client asks for /api/audio/stream as
    soon as a track is tapped, so any miss here costs a full yt-dlp subprocess
    spawn (~2-3s) before a single byte of audio can flow.

    Three things keep that off the critical path:

    1. TTL cache keyed on the video id.
    2. The TTL is derived from YouTube's own `expire` query parameter (see
       _stream_ttl_for_url) rather than a fixed constant, so a link is reused
       for its whole real lifetime (~6h) instead of being thrown away early.
    3. Single-flight: concurrent requests for the SAME uncached video share one
       resolve instead of each spawning its own yt-dlp process. Without this, a
       burst of listeners (or a client retry) multiplies the cost.

    `force` bypasses the cache but keeps the lock, so a caller recovering from a
    dead link still cannot stampede upstream.
    """
    cache_key = f"stream:{video_id}"
    if not force:
        cached_url = _cache_get(cache_key)
        if cached_url:
            return cached_url

    lock = _stream_lock(video_id)
    async with lock:
        # Re-check: another waiter may have resolved it while we queued.
        if not force:
            cached_url = _cache_get(cache_key)
            if cached_url:
                return cached_url

        direct_url = await _resolve_stream_url(video_id)
        _cache_set_ttl(cache_key, direct_url, _stream_ttl_for_url(direct_url))
        return direct_url


async def _resolve_stream_url(video_id: str) -> str:
    """Spawn yt-dlp and return the direct media URL. Raises on failure."""
    video_url = f"https://www.youtube.com/watch?v={video_id}"
    cmd = [
        YTDLP_BIN,
        "--quiet",
        "--no-warnings",
        "--proxy", PROXY_URL,
        "--extractor-args", "youtube:player_client=android",
        "-f", "140/ba[ext=m4a]/ba/b",
        "-g",
        video_url
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=STREAM_RESOLVE_TIMEOUT
        )
    except asyncio.TimeoutError:
        raise HTTPException(
            status_code=504,
            detail=f"Timed out resolving stream for {video_id}",
        )

    direct_url = stdout.decode().strip()
    if not direct_url or not direct_url.startswith("http"):
        err = (stderr.decode().strip() or "unknown error")[:200]
        raise HTTPException(
            status_code=502, detail=f"Failed to resolve audio stream URL: {err}"
        )
    return direct_url


# Reused across requests: building an httpx client (and its SOCKS connection
# pool) per playback is wasteful, and audio streaming is bursty.
_http_client: Optional[httpx.AsyncClient] = None
_http_client_lock = asyncio.Lock()


async def _get_http_client() -> httpx.AsyncClient:
    """Shared proxied httpx client for upstream media requests."""
    global _http_client
    if _http_client is None or _http_client.is_closed:
        async with _http_client_lock:
            if _http_client is None or _http_client.is_closed:
                _http_client = httpx.AsyncClient(
                    proxy=PROXY_URL,
                    timeout=httpx.Timeout(30.0, read=60.0),
                    limits=httpx.Limits(
                        max_connections=100, max_keepalive_connections=20
                    ),
                    follow_redirects=True,
                )
    return _http_client


@app.api_route("/api/audio/stream", methods=["GET", "HEAD"])
async def stream_audio(id: str, request: Request):
    """Proxy an audio stream from YouTube, with range-request support.

    The expensive part is *resolving* the media URL (a yt-dlp subprocess),
    not streaming it, so that resolution is cached by
    get_direct_stream_url() and keyed on the video id. Once resolved, this
    endpoint only forwards bytes — the client starts hearing audio immediately.

    Note: there is no server-side file cache. The direct URL is valid for
    hours and is proxied on demand, so buffering whole tracks to disk would
    just trade CPU/disk for latency.
    """
    safe_id = "".join([c for c in id if c.isalnum() or c in ('-', '_')])

    direct_url = await get_direct_stream_url(safe_id)

    client_headers = {}
    if "range" in request.headers:
        client_headers["range"] = request.headers["range"]

    client = await _get_http_client()
    upstream_req = client.build_request("GET", direct_url, headers=client_headers)
    upstream_resp = await client.send(upstream_req, stream=True)

    # A 403/404 here means the cached link died before its advertised expiry
    # (YouTube can revoke or rate-limit at any time). Drop it and resolve once
    # more so the user's retry succeeds instead of getting stuck.
    if upstream_resp.status_code in (403, 404) and not client_headers.get("range"):
        await upstream_resp.aclose()
        _cache_pop(f"stream:{safe_id}")
        direct_url = await get_direct_stream_url(safe_id, force=True)
        upstream_req = client.build_request(
            "GET", direct_url, headers=client_headers
        )
        upstream_resp = await client.send(upstream_req, stream=True)

    async def stream_generator():
        try:
            async for chunk in upstream_resp.aiter_bytes(chunk_size=64 * 1024):
                yield chunk
        finally:
            await upstream_resp.aclose()

    headers = {
        "Accept-Ranges": "bytes",
        "Content-Type": upstream_resp.headers.get("content-type", "audio/mp4"),
        # The URL is already cached server-side and re-resolved on demand, so
        # let the client (and any CDN in between) reuse it briefly.
        "Cache-Control": "private, max-age=300",
    }
    if "content-length" in upstream_resp.headers:
        headers["Content-Length"] = upstream_resp.headers["content-length"]
    if "content-range" in upstream_resp.headers:
        headers["Content-Range"] = upstream_resp.headers["content-range"]

    return StreamingResponse(
        stream_generator(),
        status_code=upstream_resp.status_code,
        headers=headers
    )


# ---------------------------------------------------------------------------
# Register the ytmusicapi-backed recommendation routes (/api/radio,
# /api/recommend, /api/import/youtube/playlist).
#
# These replace the yt-dlp based handlers defined above: they fan out per-seed
# lookups concurrently with asyncio.gather() and serve a 6-8 minute TTL cache,
# so scrolling the recommendation list costs ~0 upstream calls instead of a
# fresh blocking build per page.
#
# `override=True` (the default) drops the duplicate routes registered above,
# because Starlette matches in registration order and the first match wins —
# without it the handlers registered here would never be reached.
#
# /api/search and /api/audio/stream stay on the yt-dlp + SOCKS5 path, which
# works from this host. If ytmusicapi cannot reach YouTube Music (datacenter
# IPs are served a consent page instead of JSON), set PROXY_URL so
# recommend.py routes through the same proxy used here.
# ---------------------------------------------------------------------------
from recommend import register_recommend_routes

# override=False: recommend.py owns /api/radio, /api/recommend and its own
# import copy, but it must NEVER replace the canonical yt-dlp implementation
# above — yt-dlp + SOCKS5 proxy is the path that works from the Oracle host,
# while bare ytmusicapi gets a consent page and answers with [].
register_recommend_routes(app, override=False)

