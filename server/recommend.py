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

import asyncio
import functools
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, Coroutine, Iterable, TypeVar

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

# ---------------------------------------------------------------------------
# Perf: TTL caches + async fan-out.
#
# Everything below is I/O-bound (ytmusicapi / Last.fm / Deezer / yt-dlp), so
# the whole recommendation pipeline is `async` and fans out with
# `asyncio.gather(..., return_exceptions=True)`:
#
#   * one failing/timing-out seed or upstream returns None instead of
#     propagating, so a single bad source can never abort the response
#     (partial results always come back);
#   * the blocking ytmusicapi/`requests` calls themselves run in a *dedicated*
#     thread pool via `_to_thread`, so nested fan-out (per-seed lookups inside
#     a per-seed task) can never starve a fixed-size pool and deadlock.
#
# Synchronous wrappers (`build_recommendations`, `build_recommendations_cached`)
# are kept for Flask deployments and for callers outside an event loop; they
# simply drive the same async core with `_run_sync`.
# ---------------------------------------------------------------------------

# Dedicated pool for the blocking library calls. Deliberately separate from
# asyncio's default executor and large enough for nested fan-out.
_BLOCKING_POOL = ThreadPoolExecutor(
    max_workers=24, thread_name_prefix="opentube-blocking"
)

# Per-key locks for single-flight caching: concurrent identical requests share
# one upstream round-trip instead of stampeding ytmusicapi (thundering herd).
_KEY_LOCKS: dict[str, threading.Lock] = {}
_KEY_LOCKS_GUARD = threading.Lock()

# asyncio.Lock objects are bound to the event loop that first uses them, so
# async single-flight locks are keyed by (loop, cache key).
_ASYNC_KEY_LOCKS: dict[tuple[int, str], asyncio.Lock] = {}

SEARCH_TTL = 8 * 60  # search results / import metadata: 8 min (5-10 min band)
RECOMMEND_TTL = 6 * 60  # assembled recommendations: 6 min
MAX_CACHE_ENTRIES = 2000  # bound the in-process cache (per worker)

# Upstream budgets: keep total latency well under the 45 s client timeout.
SEED_TIMEOUT = 20.0  # one seed's full fan-out
SEED_INNER_TIMEOUT = 8.0  # one source inside a seed
BUILD_TIMEOUT = 35.0  # whole recommendation build
POOL_TIMEOUT = 8.0  # discovery fan-out per seed
BUILD_HARD_TIMEOUT = 32.0  # hard cap on the assembled build
YT_TIMEOUT = 15.0  # per-request timeout for the ytmusicapi session

T = TypeVar("T")

# ---------------------------------------------------------------------------
# TTL cache: key -> (expires_at, value).
#
# Guarded by a lock because Flask serves requests from multiple threads and
# asyncio handlers may also read it from worker threads.
# ---------------------------------------------------------------------------
_TTL_STORE: dict[str, tuple[float, Any]] = {}
_TTL_LOCK = threading.Lock()


def _evict_locked() -> None:
    """Drop expired entries (caller holds _TTL_LOCK); hard-trim if needed."""
    now = time.time()
    if len(_TTL_STORE) <= MAX_CACHE_ENTRIES:
        return
    dead = [k for k, (exp, _) in _TTL_STORE.items() if exp <= now]
    for k in dead:
        _TTL_STORE.pop(k, None)
    # Still too big (all entries fresh): drop the oldest-expiring half so the
    # per-worker footprint stays bounded instead of growing without limit.
    if len(_TTL_STORE) > MAX_CACHE_ENTRIES:
        ordered = sorted(_TTL_STORE.items(), key=lambda kv: kv[1][0])
        for k, _ in ordered[: len(_TTL_STORE) - MAX_CACHE_ENTRIES // 2]:
            _TTL_STORE.pop(k, None)


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
        _evict_locked()
        _TTL_STORE[key] = (time.time() + ttl, value)


def _key_lock(key: str) -> threading.Lock:
    with _KEY_LOCKS_GUARD:
        lock = _KEY_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            if len(_KEY_LOCKS) > MAX_CACHE_ENTRIES:
                _KEY_LOCKS.clear()
            _KEY_LOCKS[key] = lock
        return lock


def _async_key_lock(key: str) -> asyncio.Lock:
    """Per-(event loop, key) lock so concurrent identical async calls are
    de-duplicated into a single upstream round-trip (single flight)."""
    loop_key = (id(asyncio.get_running_loop()), key)
    with _KEY_LOCKS_GUARD:
        lock = _ASYNC_KEY_LOCKS.get(loop_key)
        if lock is None:
            lock = asyncio.Lock()
            if len(_ASYNC_KEY_LOCKS) > MAX_CACHE_ENTRIES:
                _ASYNC_KEY_LOCKS.clear()
            _ASYNC_KEY_LOCKS[loop_key] = lock
        return lock


def ttl_cache(ttl: float, key_fn: Callable[..., str]):
    """Decorator: cache a blocking function's results for `ttl` seconds.

    Failures are never cached — a timed-out upstream must not poison later
    requests. Single-flight: concurrent identical calls share one round-trip.
    Cache is in-process (per server worker).
    """

    def deco(fn: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> T:
            try:
                key = key_fn(*args, **kwargs)
            except Exception:
                # Unhashable/odd args: skip caching rather than break the call.
                return fn(*args, **kwargs)
            hit = _ttl_get(key)
            if hit is not None:
                return hit
            with _key_lock(key):
                # Re-check: another thread may have populated it meanwhile.
                hit = _ttl_get(key)
                if hit is not None:
                    return hit
                value = fn(*args, **kwargs)
                _ttl_set(key, value, ttl)
                return value

        return wrapper

    return deco


async def _to_thread(fn: Callable[..., T], *args: Any, **kwargs: Any) -> T:
    """Run a blocking call off the event loop (never blocks other coros)."""
    return await asyncio.get_running_loop().run_in_executor(
        _BLOCKING_POOL, functools.partial(fn, *args, **kwargs)
    )


async def _gather(
    tasks: Iterable[tuple[str, Callable[[], Coroutine[Any, Any, T]]]],
    timeout: float | None = None,
) -> dict[str, T | None]:
    """Await many coroutine factories concurrently — the asyncio.gather
    equivalent of a multi-source fan-out.

    Behaves like ``asyncio.gather(..., return_exceptions=True)`` plus a wall
    clock budget: a slow or failing source yields None for its slot instead of
    blocking or crashing the rest of the response, so callers always get
    partial results. `timeout` cancels stragglers but keeps everything that
    already finished.
    """
    items = list(tasks)
    if not items:
        return {}

    async def run(name: str, factory: Callable[[], Coroutine[Any, Any, T]]):
        try:
            if timeout is not None:
                return await asyncio.wait_for(factory(), timeout)
            return await factory()
        except Exception:
            # Includes asyncio.TimeoutError: partial-safe by design.
            return None

    results = await asyncio.gather(*(run(name, fn) for name, fn in items))
    return dict(zip((name for name, _ in items), results))


async def _cached_async(
    key: str,
    ttl: float,
    factory: Callable[[], Coroutine[Any, Any, T | None]],
) -> T | None:
    """TTL cache for async lookups, with single-flight de-duplication.

    Concurrent identical requests share ONE upstream round-trip instead of
    stampeding ytmusicapi/Last.fm. `factory` returns None to signal failure,
    and failures are never cached, so a timed-out upstream never poisons
    later requests.
    """
    hit = _ttl_get(key)
    if hit is not None:
        return hit
    async with _async_key_lock(key):
        hit = _ttl_get(key)
        if hit is not None:
            return hit
        try:
            value = await factory()
        except Exception:
            return None
        if value is not None:
            _ttl_set(key, value, ttl)
        return value


def _run_sync(coro: Coroutine[Any, Any, T]) -> T:
    """Drive the async core from sync code (Flask handlers, tests, scripts).

    Uses a private event loop in a worker thread when a loop is already
    running, so this is safe from any context.
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    with ThreadPoolExecutor(max_workers=1, thread_name_prefix="opentube-sync") as ex:
        return ex.submit(asyncio.run, coro).result()


def _run_sync_batch(items: list[Callable[[], Coroutine[Any, Any, T]]]) -> list[Any]:
    """Run several independent async operations concurrently from sync code.

    Used by Flask deployments to fan out without blocking the worker thread
    on a single call at a time.
    """
    async def _all():
        return await asyncio.gather(*(fn() for fn in items), return_exceptions=True)

    return _run_sync(_all())


__all__ = [
    "register_recommend_routes",
    "build_recommendations",
    "build_recommendations_async",
    "build_recommendations_cached",
    "build_recommendations_cached_async",
    "radio_for",
    "radio_for_async",
    "playlist_tracks",
    "playlist_tracks_async",
    "yt_search",
    "yt_search_async",
    "lastfm_similar",
    "lastfm_similar_async",
    "lastfm_similar_artists",
    "lastfm_similar_artists_async",
    "deezer_related_artists",
    "deezer_related_artists_async",
    "ttl_cache",
    "SEARCH_TTL",
    "RECOMMEND_TTL",
]


_yt = None
_yt_lock = threading.Lock()

# Optional upstream proxy. On datacenter IPs (e.g. Oracle Cloud) YouTube
# serves a consent/bot interstitial instead of JSON, and ytmusicapi then dies
# with a KeyError while parsing the response. Routing it through the same
# SOCKS5 proxy main.py already uses for yt-dlp fixes that.
#
# Set YTMUSIC_PROXY (or PROXY_URL, to match main.py) to enable.
PROXY_URL = os.environ.get("YTMUSIC_PROXY") or os.environ.get("PROXY_URL") or ""


def _yt_requests_session():
    """A requests.Session for ytmusicapi, optionally routed via a proxy.

    Returns None when no proxy is configured, so ytmusicapi builds its own
    default session.

    Note: ytmusicapi only applies its 30s timeout to sessions it creates
    itself (`_prepare_session`), so an explicit timeout is set here.
    """
    if not PROXY_URL:
        return None
    try:
        session = requests.Session()
        session.proxies = {"http": PROXY_URL, "https": PROXY_URL}
    except Exception:
        # Could not build a session at all: fall back to ytmusicapi's default.
        return None
    # A desktop UA avoids some interstitials even before proxying.
    try:
        session.headers.setdefault(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        )
    except Exception:
        pass
    # ytmusicapi only applies its 30s timeout to sessions it creates itself
    # (_prepare_session), so bind one explicitly. Non-fatal if unavailable.
    try:
        session.request = functools.partial(session.request, timeout=YT_TIMEOUT)
    except Exception:
        pass
    return session


def _ytmusic():
    """Lazily build the YTMusic client. Thread-safe: parallel fan-out may hit
    this from several worker threads at once, and we must not double-build."""
    global _yt
    if _yt is None:
        with _yt_lock:
            if _yt is None:
                if YTMusic is None:
                    raise RuntimeError("ytmusicapi is not installed")
                session = _yt_requests_session()
                proxies = (
                    {"http": PROXY_URL, "https": PROXY_URL} if PROXY_URL else None
                )
                try:
                    # ytmusicapi >=1.x accepts `requests_session`; `proxies`
                    # is the belt-and-braces path for uploads/other calls.
                    _yt = YTMusic(requests_session=session, proxies=proxies)
                except TypeError:
                    try:
                        _yt = YTMusic(proxies=proxies)
                    except TypeError:
                        # Very old signature: no proxy support at all.
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
    """Watch-playlist radio (sync entry point, TTL cached, partial-safe)."""
    return _run_sync(radio_for_async(video_id, limit))


RADIO_TTL = 6 * 60 * 60  # radio mixes are stable; 6h keeps the app snappy

# Last-known-good radio mixes: if ytmusicapi fails we still serve something
# instead of an empty radio (stale is better than nothing).
_RADIO_STALE: dict[str, list[dict]] = {}
_RADIO_LOCK = threading.Lock()


def _fetch_radio(video_id: str, limit: int) -> list[dict]:
    """Blocking watch-playlist fetch. Raises on upstream failure.

    This is the real YouTube Music radio mix and the preferred path. It needs
    ytmusicapi >= 1.11 (the fix for the watch-playlist 'endpoint' KeyError);
    those releases require Python >= 3.10. On older stacks the parse raises,
    and `radio_for_async` falls back to `_fetch_radio_fallback`.
    """
    watch = _ytmusic().get_watch_playlist(videoId=video_id, limit=limit + 4)
    tracks: list[dict] = []
    for item in watch.get("tracks") or []:
        parsed = _track_from_yt(item)
        if parsed and parsed["id"] != video_id:
            tracks.append(parsed)
        if len(tracks) >= limit:
            break
    if tracks:
        return tracks
    # Parsed OK but empty: treat as a soft failure so the fallback runs.
    raise RuntimeError("watch playlist returned no tracks")


def _fetch_radio_fallback(video_id: str, limit: int) -> list[dict]:
    """Fallback radio for hosts where get_watch_playlist cannot be parsed.

    Only used when the primary path raises — i.e. ytmusicapi < 1.11 on
    Python 3.9, where the watch-playlist parser raises KeyError for every
    video and `get_song` returns just videoDetails (no artist/album ids). We
    read the seed's artist/title from get_song and rebuild the mix with the
    filtered searches that DO parse there.

    On ytmusicapi >= 1.11 / Python >= 3.10 this is never reached, because
    _fetch_radio succeeds.
    """
    ytm = _ytmusic()
    try:
        song = ytm.get_song(video_id) or {}
    except Exception:
        return []
    details = song.get("videoDetails") or {}
    artist = (details.get("author") or "").strip()
    title = (details.get("title") or "").strip()
    if not artist and not title:
        return []

    tracks: list[dict] = []
    seen: set[str] = {video_id}

    def _extend(items: Any) -> None:
        for item in items or []:
            parsed = _track_from_yt(item)
            if not parsed or parsed["id"] in seen:
                continue
            seen.add(parsed["id"])
            tracks.append(parsed)
            if len(tracks) >= limit:
                return

    # filter="songs" parses even on the old ytmusicapi; the unfiltered search
    # is the one that trips #799 there.
    for query in (f"{artist} {title}".strip(), artist, title):
        if not query or len(tracks) >= limit:
            continue
        try:
            _extend(ytm.search(query, filter="songs", limit=limit + 5) or [])
        except Exception:
            continue

    if not tracks:
        raise RuntimeError("radio fallback found no tracks")
    return tracks


def _remember_radio(video_id: str, tracks: list[dict]) -> None:
    if tracks:
        with _RADIO_LOCK:
            _RADIO_STALE[video_id] = list(tracks)


def _stale_radio(video_id: str, limit: int) -> list[dict]:
    with _RADIO_LOCK:
        old = _RADIO_STALE.get(video_id)
    return list(old[:limit]) if old else []


async def radio_for_async(video_id: str, limit: int = 20) -> list[dict]:
    """Radio for one seed: cached, off-thread, and failure-tolerant."""
    vid = (video_id or "").strip()
    if not vid:
        return []
    key = f"radio:{vid}|{limit}"

    async def factory() -> list[dict] | None:
        # Primary path first; on failure try the metadata-based fallback so
        # hosts with an unparseable watch-playlist still get a real mix.
        for fetch in (_fetch_radio, _fetch_radio_fallback):
            try:
                tracks = await _to_thread(fetch, vid, limit)
            except Exception:
                continue
            if tracks:
                _remember_radio(vid, tracks)
                return tracks
        return None  # never cache a total failure

    out = await _cached_async(key, RADIO_TTL, factory)
    return _stale_radio(vid, limit) if out is None else out


def lastfm_similar(artist: str, title: str, limit: int = 10) -> list[dict]:
    """Sync entry point for Last.fm similar tracks (TTL cached)."""
    return _run_sync(lastfm_similar_async(artist, title, limit))


async def lastfm_similar_async(artist: str, title: str, limit: int = 10) -> list[dict]:
    if not LASTFM_API_KEY or not artist or not title:
        return []

    def fetch() -> list[dict] | None:
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
                timeout=6,
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
            return None

    out = await _cached_async(
        f"lfm_tr:{artist.strip().lower()}|{title.strip().lower()}|{limit}",
        SEARCH_TTL,
        lambda: _to_thread(fetch),
    )
    return out or []


def lastfm_similar_artists(artist: str, limit: int = 6) -> list[str]:
    """Sync entry point for Last.fm similar artists (TTL cached)."""
    return _run_sync(lastfm_similar_artists_async(artist, limit))


async def lastfm_similar_artists_async(artist: str, limit: int = 6) -> list[str]:
    if not LASTFM_API_KEY or not artist:
        return []

    def fetch() -> list[str] | None:
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
                timeout=6,
            )
            artists = (((res.json() or {}).get("similarartists") or {}).get("artist")) or []
            return [a.get("name") for a in artists if a.get("name")][:limit]
        except Exception:
            return None

    out = await _cached_async(
        f"lfm_ar:{artist.strip().lower()}|{limit}", SEARCH_TTL, lambda: _to_thread(fetch)
    )
    return out or []


def deezer_related_artists(artist: str, title: str, limit: int = 5) -> list[str]:
    """Sync entry point for Deezer related artists (TTL cached)."""
    return _run_sync(deezer_related_artists_async(artist, title, limit))


async def deezer_related_artists_async(artist: str, title: str, limit: int = 5) -> list[str]:
    def fetch() -> list[str] | None:
        try:
            search = requests.get(
                "https://api.deezer.com/search/track",
                params={"q": f"{artist} {title}"},
                timeout=6,
            ).json()
            data = search.get("data") or []
            if not data:
                return None
            artist_id = ((data[0].get("artist") or {}).get("id"))
            if not artist_id:
                return None
            rel = requests.get(
                f"https://api.deezer.com/artist/{artist_id}/related",
                timeout=6,
            ).json()
            return [a.get("name") for a in (rel.get("data") or []) if a.get("name")][:limit]
        except Exception:
            return None

    out = await _cached_async(
        f"dz:{artist.strip().lower()}|{title.strip().lower()}|{limit}",
        SEARCH_TTL,
        lambda: _to_thread(fetch),
    )
    return out or []


def yt_search(query: str, limit: int = 5) -> list[dict]:
    """Sync entry point for YouTube Music search (TTL cached)."""
    return _run_sync(yt_search_async(query, limit))


async def yt_search_async(query: str, limit: int = 5) -> list[dict]:
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

    def search_once(**kwargs: Any) -> list[dict]:
        """One blocking ytmusicapi search variant; returns [] on failure."""
        try:
            results = _ytmusic().search(query, **kwargs) or []  # type: ignore[arg-type]
        except Exception:
            return []
        out: list[dict] = []
        for item in results:
            parsed = _track_from_yt(item)
            if parsed:
                out.append(parsed)
            if len(out) >= limit:
                break
        return out

    async def factory() -> list[dict] | None:
        try:
            # Both variants are independent, so run them concurrently.
            #
            # The unfiltered search is tried first because it surfaces
            # unofficial/UGC uploads (underground mixtape cuts, edits). It is
            # also the variant that hits ytmusicapi issue #799 ("Unable to find
            # 'header' using path ['header', 'musicCardShelfHeaderBasicRenderer'
            # ...") when YouTube omits the "Top result" card — that raises
            # KeyError on ytmusicapi < 1.11, the last release supporting
            # Python 3.9. Running it alongside filter="songs" means a #799
            # failure on one variant costs only the songs half of the results.
            variants = await asyncio.gather(
                _to_thread(search_once, limit=fetch_n),
                _to_thread(search_once, filter="songs", limit=fetch_n),
                return_exceptions=True,
            )
        except Exception:
            return None
        merged: list[dict] = []
        seen: set[str] = set()
        for variant in variants:
            if isinstance(variant, BaseException) or not variant:
                continue
            for parsed in variant:
                if parsed["id"] in seen:
                    continue
                seen.add(parsed["id"])
                merged.append(parsed)
                if len(merged) >= limit:
                    return merged
        # A genuinely empty result is still a valid, cacheable answer.
        return merged

    out = await _cached_async(
        f"ytq:{query.lower()}|{limit}", SEARCH_TTL, factory
    )
    return out or []


def build_recommendations(payload: dict[str, Any]) -> list[dict]:
    """Sync entry point (Flask / scripts). Drives the async core."""
    return _run_sync(build_recommendations_async(payload))


def _normalize_seeds(seeds: Any) -> list[dict]:
    """Coerce the client's seed list into dicts with a usable numeric score.

    The Flutter client can legitimately send odd shapes (nulls, raw strings,
    missing fields) and one malformed entry must never crash the whole build —
    it is simply skipped.
    """

    def _coerce(seed: Any) -> dict | None:
        if isinstance(seed, dict):
            row = dict(seed)
        elif isinstance(seed, str):
            row = {"id": seed}
        else:
            return None
        try:
            row["score"] = float(row.get("score") or 0)
        except (TypeError, ValueError):
            row["score"] = 0.0
        return row

    return [row for row in (_coerce(s) for s in seeds or []) if row is not None]


async def build_recommendations_async(payload: dict[str, Any]) -> list[dict]:
    if not isinstance(payload, dict):
        return []
    seeds = _normalize_seeds(payload.get("seeds"))
    exclude = {str(x) for x in (payload.get("exclude_ids") or [])}
    try:
        limit = int(payload.get("limit") or 20)
    except (TypeError, ValueError):
        limit = 20
    limit = min(max(limit, 1), 100)
    for seed in seeds:
        sid = seed.get("id")
        if sid:
            exclude.add(str(sid))

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

    async def process_seed(seed: dict) -> None:
        """All lookups for ONE seed, fanned out concurrently.

        Any single lookup may fail or time out; `_gather` turns that into None
        for its slot, so one bad seed never blocks or crashes the whole
        response — partial results still rank below.
        """
        try:
            vid = seed.get("id") or ""
            seed_id = vid or f"{seed.get('artist')}|{seed.get('title')}"
            weight = float(seed.get("score") or 1)
            artist = (seed.get("artist") or "").strip()
            title = (seed.get("title") or "").strip()

            seed_queries: list[str] = []
            if artist and title:
                seed_queries.append(f"{artist} {title}")
            if artist:
                seed_queries.append(artist)
            if title and title.lower() not in artist.lower():
                seed_queries.append(title)

            # Fan out this seed's independent sources concurrently
            # (radio + last.fm similars + direct metadata queries).
            inner: list[tuple[str, Callable[[], Coroutine[Any, Any, Any]]]] = []
            if vid:
                inner.append((f"{seed_id}|radio", lambda: radio_for_async(vid, 16)))
            inner.append(
                (f"{seed_id}|lfm", lambda: lastfm_similar_async(artist, title, 8))
            )
            for q in seed_queries:
                inner.append(
                    (f"{seed_id}|q:{q}", (lambda qq: lambda: yt_search_async(qq, 4))(q))
                )
            got = await _gather(inner, timeout=SEED_TIMEOUT)

            for t in got.get(f"{seed_id}|radio") or []:
                if isinstance(t, dict):
                    add(t, weight, discovery=False, seed_id=seed_id)

            # Last.fm similars must be resolved back to YouTube ids. Those
            # depend on the similar list, so they form a second wave that is
            # itself concurrent (previously a serial for-loop).
            sims = [
                sim
                for sim in (got.get(f"{seed_id}|lfm") or [])
                if isinstance(sim, dict)
            ]
            if sims:
                sim_wave = await _gather(
                    [
                        (
                            f"{seed_id}|sim:{i}",
                            (
                                lambda s: lambda: yt_search_async(
                                    f"{s.get('artist')} {s.get('title')}", limit=2
                                )
                            )(sim),
                        )
                        for i, sim in enumerate(sims)
                    ],
                    timeout=SEED_INNER_TIMEOUT,
                )
                for i in range(len(sims)):
                    for t in sim_wave.get(f"{seed_id}|sim:{i}") or []:
                        if isinstance(t, dict):
                            add(t, weight * 0.85, discovery=False, seed_id=seed_id)
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

    async def process_discovery(seed: dict) -> None:
        try:
            vid = seed.get("id") or ""
            seed_id = vid or f"{seed.get('artist')}|{seed.get('title')}"
            weight = float(seed.get("score") or 1) * 0.45
            artist = (seed.get("artist") or "").strip()
            # Last.fm first, Deezer as fallback. Each is individually
            # failure-tolerant, so a dead Last.fm key degrades quietly.
            names = await lastfm_similar_artists_async(artist, 4)
            if not names:
                names = await deezer_related_artists_async(
                    artist, seed.get("title") or "", 4
                )
            if not names:
                return
            got = await _gather(
                [
                    (
                        f"{seed_id}|rel:{n}",
                        (lambda nn: lambda: yt_search_async(nn, 3))(n),
                    )
                    for n in names
                ],
                timeout=POOL_TIMEOUT,
            )
            for n in names:
                for t in got.get(f"{seed_id}|rel:{n}") or []:
                    if isinstance(t, dict):
                        add(t, weight, discovery=True, seed_id=seed_id)
        except Exception:
            return

    async def run_build() -> None:
        # Core and discovery seeds are independent waves: run them together
        # instead of core-then-discovery (halves the critical path).
        core_tasks = [
            (f"seed:{i}", (lambda s: lambda: process_seed(s))(seed))
            for i, seed in enumerate(ranked_seeds[:12])
        ]
        disc_tasks = [
            (f"disc:{i}", (lambda s: lambda: process_discovery(s))(seed))
            for i, seed in enumerate(ranked_seeds[:8])
        ]
        await _gather([*core_tasks, *disc_tasks], timeout=BUILD_TIMEOUT)

    await run_build()

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
    """Cache key for the assembled candidate pool.

    Deliberately EXCLUDES `exclude_ids`: the Flutter client re-sends a growing
    exclude set on every scroll, so folding it into the key would produce a
    fresh key per page and make the cache useless. We cache the unfiltered
    pool and apply the caller's excludes when slicing (see
    `build_recommendations_cached`).
    """
    try:
        if not isinstance(payload, dict):
            raise TypeError("payload must be a dict")
        seeds = payload.get("seeds") or []
        parts = sorted(
            _seed_key_part(s) for s in _normalize_seeds(seeds)
        )
        return f"rec:{'|'.join(parts)}#{payload.get('limit')}"
    except Exception:
        # Unhashable/odd payload: never cache (unique key every call).
        return f"rec:{time.time_ns()}"


def _seed_key_part(seed: dict) -> str:
    return (
        f"{seed.get('id')}|{seed.get('artist')}|{seed.get('title')}"
        f"|{seed.get('score')}"
    )


def _pool_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Payload used to build the cached candidate pool.

    Over-fetches and drops the caller's excludes so one cached pool serves
    many pages/searches.
    """
    try:
        limit = int(payload.get("limit") or 20)
    except (TypeError, ValueError):
        limit = 20
    limit = min(max(limit, 1), 100)
    pool = dict(payload)
    pool.pop("exclude_ids", None)
    pool["limit"] = min(limit * 2, 100)
    return pool


async def build_recommendations_cached_async(
    payload: dict[str, Any]
) -> list[dict]:
    """TTL-cached, single-flight /api/recommend entry point.

    Concurrent identical requests share ONE build instead of stampeding
    ytmusicapi (thundering herd on app start).
    """
    if not isinstance(payload, dict):
        return []
    key = _recommend_cache_key(payload)
    pool_payload = _pool_payload(payload)

    async def factory() -> list[dict] | None:
        try:
            return await asyncio.wait_for(
                build_recommendations_async(pool_payload), BUILD_HARD_TIMEOUT
            )
        except Exception:
            return None  # never cache a failed build

    pool = await _cached_async(key, RECOMMEND_TTL, factory)

    # Re-apply the caller's excludes / limit on every request, cached or not.
    try:
        limit = min(max(int(payload.get("limit") or 20), 1), 100)
    except (TypeError, ValueError):
        limit = 20
    exclude = {str(x) for x in (payload.get("exclude_ids") or [])}
    for seed in _normalize_seeds(payload.get("seeds")):
        sid = seed.get("id")
        if sid:
            exclude.add(str(sid))
    return [
        dict(t) for t in (pool or []) if str(t.get("id")) not in exclude
    ][:limit]


def build_recommendations_cached(payload: dict[str, Any]) -> list[dict]:
    """Sync entry point (Flask / scripts)."""
    return _run_sync(build_recommendations_cached_async(payload))


def playlist_tracks(playlist_id: str, limit: int = 200) -> list[dict]:
    """Sync entry point for playlist import (TTL cached)."""
    return _run_sync(playlist_tracks_async(playlist_id, limit))


async def playlist_tracks_async(playlist_id: str, limit: int = 200) -> list[dict]:
    """Fetch tracks of a YouTube / YouTube Music playlist via ytmusicapi."""
    pid = (playlist_id or "").strip()
    if not pid:
        return []
    cap = min(max(limit, 1), 500)

    def fetch() -> list[dict] | None:
        try:
            ytm = _ytmusic()
        except Exception:
            return None
        try:
            data = ytm.get_playlist(playlistId=pid, limit=cap)
        except Exception:
            # Some ytmusicapi versions use `playlist_id` instead of `playlistId`.
            try:
                data = ytm.get_playlist(playlist_id=pid, limit=cap)  # type: ignore[call-arg]
            except Exception:
                return None
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
                    "playlistId": pid,
                    "source": "yt",
                }
            )
            if len(out) >= cap:
                break
        return out

    out = await _cached_async(
        f"pl:{pid}|{cap}", SEARCH_TTL, lambda: _to_thread(fetch)
    )
    return out or []


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


# Paths this module owns. Used to detect/override collisions when wiring into
# an app that already defines them (main.py does).
_RECOMMEND_PATHS = {
    "/api/radio",
    "/api/recommend",
    "/api/import/youtube/playlist",
}


def _remove_existing_routes(app, paths: set[str]) -> list[str]:
    """Drop already-registered routes for `paths` from a Starlette/FastAPI app.

    Starlette matches routes in registration order, so when this module is
    wired into an app that already defines /api/recommend (main.py does), the
    EARLIER handler wins and the ones registered here would be dead code.
    Removing the pre-existing entries makes these handlers authoritative.

    Returns the (method, path) pairs that were removed, for logging.
    """
    removed: list[str] = []
    router = getattr(app, "router", None)
    if router is None:
        return removed
    routes = getattr(router, "routes", None)
    if not routes:
        return removed
    for route in list(routes):
        path = getattr(route, "path", None)
        if path not in paths:
            continue
        methods = sorted(getattr(route, "methods", None) or [])
        removed.append(f"{','.join(methods) or '?'} {path}")
        try:
            routes.remove(route)
        except Exception:
            pass
    return removed


def _detect_host_proxy(app) -> str:
    """Find the proxy the host app uses, if any.

    main.py keeps its proxy as a *module-level* global rather than an app
    attribute, so we look at the calling module's globals as well as the app
    object itself. Returning "" means "no proxy configured".
    """
    candidates = [
        getattr(app, "PROXY_URL", None),
        os.environ.get("PROXY_URL"),
        os.environ.get("YTMUSIC_PROXY"),
    ]
    # Walk out of this module to the frame that called us (main.py).
    try:
        frame = sys._getframe(2)
        while frame is not None:
            module_name = frame.f_globals.get("__name__", "")
            if module_name != __name__:
                candidates.append(frame.f_globals.get("PROXY_URL"))
                break
            frame = frame.f_back
    except Exception:
        pass
    for value in candidates:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def register_recommend_routes(app, override: bool = True) -> None:
    """Attach /api/radio, /api/recommend and /api/import/youtube/playlist.

    Works with BOTH FastAPI and Flask apps (auto-detected). This fixes the
    "404 Not Found on /api/recommend" bug: the handlers were previously
    Flask-only (@app.get + jsonify + request.args) and therefore never
    registered on the FastAPI server that actually serves the app.

    `override` (default True) removes any route already registered for these
    paths before adding ours, so wiring this module into main.py actually
    takes effect instead of being shadowed by Starlette's first-match-wins
    routing. Set False to keep the app's existing handlers on collision.

    If the host app uses an upstream proxy (main.py does, for yt-dlp) it is
    adopted here so ytmusicapi reaches YouTube Music the same way. Without it,
    datacenter IPs are served a consent page instead of JSON and ytmusicapi
    fails with a KeyError while parsing.

    Every endpoint is exception-safe: a failing seed or a timing-out
    upstream call (ytmusicapi / Last.fm / Deezer) yields a valid JSON body
    with partial results instead of crashing or aborting the connection.
    """
    global PROXY_URL, _yt
    host_proxy = _detect_host_proxy(app)
    if host_proxy and host_proxy != PROXY_URL:
        PROXY_URL = host_proxy
        _yt = None  # force a rebuild so the new proxy actually takes effect
        print(f"[recommend] using host PROXY_URL={host_proxy}")
    if _is_fastapi_app(app):
        if override:
            replaced = _remove_existing_routes(app, _RECOMMEND_PATHS)
            if replaced:
                print(
                    "[recommend] replacing pre-existing route(s): "
                    + "; ".join(replaced)
                )
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

    Handlers are ``async def`` and await the async core directly. The
    blocking, network-heavy work (ytmusicapi / Last.fm / Deezer) is pushed to
    a dedicated thread pool by ``_to_thread``, so the ASGI event loop never
    stalls and many requests are served concurrently.
    Query params come from ``request.query_params``; the recommend body is
    read with ``await request.json()``. Any failure returns a JSONResponse
    carrying partial results instead of raising/aborting the connection.
    """
    try:
        from fastapi import Request
        from fastapi.responses import JSONResponse
    except Exception:  # pragma: no cover - fall back to raw starlette
        from starlette.requests import Request  # type: ignore
        from starlette.responses import JSONResponse  # type: ignore

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
            tracks = await radio_for_async(video_id, offset + limit)
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
            # TTL-cached + single-flight: repeat requests return in ms, and
            # the first build fans out across all seeds concurrently.
            results = await build_recommendations_cached_async(payload)
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
            tracks = await playlist_tracks_async(raw_id, offset + limit)
            return tracks[offset : offset + limit]
        except Exception as exc:
            return _err(502, exc)
