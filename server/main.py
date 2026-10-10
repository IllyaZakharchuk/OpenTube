import asyncio
import functools
import os
import threading
import time
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

URL_CACHE_TTL = 45 * 60  # resolved stream URLs are stable for ~45 min

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
    return {
        "id": vid,
        "videoId": vid,
        "title": entry.get("title") or "",
        "uploader": uploader,
        "artist": uploader,
        "duration": entry.get("duration"),
        "thumbnail": thumb,
        "artworkUrl": thumb,
        "url": f"https://www.youtube.com/watch?v={vid}",
    }


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
        count = offset + limit
        query = f"ytsearch{count}:{q}"
        return await to_thread(_extract_flat, query, count)

    results = await cached(cache_key, TTL_SECONDS, producer)
    return {"query": q, "results": (results or [])[offset:offset + limit]}


@app.get("/api/import/youtube/playlist")
async def import_youtube_playlist(playlist_id: str = None, url: str = None,
                                  limit: int = None, offset: int = 0):
    target_url = url if url else f"https://www.youtube.com/playlist?list={playlist_id}"
    # Import metadata is expensive and rarely changes: cache the parsed result.
    cache_key = f"import_pl:{target_url}"

    async def producer():
        ydl_opts = get_ydl_opts({'extract_flat': 'in_playlist'})
        return await to_thread(_extract_playlist_info, target_url, ydl_opts)

    res = await cached(cache_key, TTL_SECONDS, producer)
    if res is None:
        raise HTTPException(status_code=400, detail="Failed to parse playlist")
    offset = max(0, offset)
    tracks = res.get("tracks") or []
    if limit:
        tracks = tracks[offset:offset + max(1, min(limit, 500))]
    else:
        tracks = tracks[offset:]
    return {
        "title": res.get("title") or "YouTube Playlist",
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


async def get_direct_stream_url(video_id: str) -> str:
    cached_url = _cache_get(f"stream:{video_id}")
    if cached_url:
        return cached_url

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

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    stdout, _ = await proc.communicate()

    direct_url = stdout.decode().strip()
    if not direct_url or not direct_url.startswith("http"):
        raise HTTPException(status_code=500, detail="Failed to resolve audio stream URL")

    _cache_set_ttl(f"stream:{video_id}", direct_url, URL_CACHE_TTL)
    return direct_url


@app.api_route("/api/audio/stream", methods=["GET", "HEAD"])
async def stream_audio(id: str, request: Request):
    safe_id = "".join([c for c in id if c.isalnum() or c in ('-', '_')])
    cached_file = os.path.join(CACHE_DIR, f"{safe_id}.m4a")

    if os.path.exists(cached_file) and os.path.getsize(cached_file) > 10000:
        return FileResponse(
            cached_file,
            media_type="audio/mp4",
            filename=f"{safe_id}.m4a"
        )

    direct_url = await get_direct_stream_url(safe_id)

    client_headers = {}
    if "range" in request.headers:
        client_headers["range"] = request.headers["range"]

    client = httpx.AsyncClient(proxy=PROXY_URL, timeout=30.0)
    upstream_req = client.build_request("GET", direct_url, headers=client_headers)
    upstream_resp = await client.send(upstream_req, stream=True)

    async def stream_generator():
        try:
            async for chunk in upstream_resp.aiter_bytes(chunk_size=64 * 1024):
                yield chunk
        finally:
            await upstream_resp.aclose()
            await client.aclose()

    headers = {
        "Accept-Ranges": "bytes",
        "Content-Type": upstream_resp.headers.get("content-type", "audio/mp4"),
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

register_recommend_routes(app)

