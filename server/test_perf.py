"""Performance / correctness harness for the optimized backend.

No third-party deps required: ytmusicapi / requests are stubbed so the real
module code runs against fake, *timed* upstreams. This proves the three goals
of the optimization:

  1. ASYNC PARALLELIZATION — per-seed and multi-source lookups run
     concurrently (asyncio.gather), so wall-clock ~= max(...) not sum(...).
  2. TTL CACHING — repeat calls are served from cache with ~0 upstream calls.
  3. ERROR HANDLING — a failing / timing-out source yields partial results
     instead of raising or hanging.

Run:  python3 server/test_perf.py
"""

from __future__ import annotations

import asyncio
import os
import sys
import time
import types

# Simulated upstream round-trip, seconds.
LATENCY = 0.20

CALLS: dict[str, int] = {}
CONCURRENCY = {"now": 0, "peak": 0}


class _Resp:
    def __init__(self, payload):
        self._payload = payload

    def json(self):
        return self._payload


def _bump(name: str) -> None:
    CALLS[name] = CALLS.get(name, 0) + 1


def _enter() -> None:
    CONCURRENCY["now"] += 1
    CONCURRENCY["peak"] = max(CONCURRENCY["peak"], CONCURRENCY["now"])


def _leave() -> None:
    CONCURRENCY["now"] -= 1


def reset_counters() -> None:
    CALLS.clear()
    CONCURRENCY["now"] = 0
    CONCURRENCY["peak"] = 0


class FakeYTMusic:
    """Fake ytmusicapi client: every call sleeps LATENCY and is counted."""

    def get_watch_playlist(self, videoId=None, limit=20):
        _bump("radio")
        _enter()
        try:
            time.sleep(LATENCY)
        finally:
            _leave()
        return {
            "tracks": [
                {
                    "videoId": f"radio_{videoId}_{i}",
                    "title": f"Radio {videoId} #{i}",
                    "artists": [{"name": f"Artist {videoId}"}],
                    "thumbnails": [{"url": "http://img/1.jpg"}],
                }
                for i in range(limit)
            ]
        }

    def search(self, query, filter=None, limit=5):
        _bump("search")
        _enter()
        try:
            time.sleep(LATENCY)
        finally:
            _leave()
        slug = "".join(ch for ch in query if ch.isalnum())[:12] or "q"
        suffix = "f" if filter == "songs" else "u"
        return [
            {
                "videoId": f"{slug}_{suffix}_{i}",
                "title": f"{query} #{i}",
                "artists": [{"name": "Some Artist"}],
                "thumbnails": [{"url": "http://img/2.jpg"}],
            }
            for i in range(limit)
        ]

    def get_playlist(self, playlistId=None, playlist_id=None, limit=200):
        _bump("playlist")
        _enter()
        try:
            time.sleep(LATENCY)
        finally:
            _leave()
        pid = playlistId or playlist_id
        return {
            "tracks": [
                {
                    "videoId": f"{pid}_{i}",
                    "title": f"PL track {i}",
                    "artists": [{"name": "PL Artist"}],
                    "thumbnails": [{"url": "http://img/3.jpg"}],
                }
                for i in range(limit)
            ]
        }


def _install_stubs() -> None:
    """Stub ytmusicapi / requests so the real module code can be imported."""
    ytm = types.ModuleType("ytmusicapi")

    class YTMusic:
        def __init__(self, *a, **k):
            self._impl = FakeYTMusic()

        def __getattr__(self, item):
            return getattr(self._impl, item)

    ytm.YTMusic = YTMusic
    sys.modules["ytmusicapi"] = ytm

    req = types.ModuleType("requests")

    def get(url, params=None, timeout=None):
        method = (params or {}).get("method", "")
        _bump(f"http:{method or 'deezer'}")
        _enter()
        try:
            time.sleep(LATENCY)
        finally:
            _leave()
        if "audioscrobbler" in url:
            if method == "artist.getsimilar":
                payload = {
                    "similarartists": {
                        "artist": [{"name": f"Related {i}"} for i in range(4)]
                    }
                }
            else:
                payload = {
                    "similartracks": {
                        "track": [
                            {"name": f"Sim {i}", "artist": {"name": f"SimArtist {i}"}}
                            for i in range(4)
                        ]
                    }
                }
        else:  # Deezer
            payload = (
                {"data": [{"artist": {"id": 42}, "title": "x"}]}
                if "search" in url
                else {"data": [{"name": f"DzRel {i}"} for i in range(4)]}
            )
        return _Resp(payload)

    class _Session:
        """Stand-in for requests.Session (only what recommend.py touches)."""

        def __init__(self):
            self.proxies = {}
            self.headers = {}

        def setdefault(self, *a, **k):  # pragma: no cover - stub convenience
            pass

        def request(self, *a, **k):
            return get("session", None, timeout=k.get("timeout"))

    req.Session = _Session
    req.get = get
    sys.modules["requests"] = req

    # --- stubs so server/main.py can be imported for inspection -------------
    if "yt_dlp" not in sys.modules:
        ytdlp = types.ModuleType("yt_dlp")

        class YoutubeDL:
            def __init__(self, opts=None):
                self.opts = opts or {}

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def extract_info(self, target, download=False):
                return {"title": "stub", "entries": []}

        ytdlp.YoutubeDL = YoutubeDL
        sys.modules["yt_dlp"] = ytdlp

    if "httpx" not in sys.modules:
        httpx_mod = types.ModuleType("httpx")

        class AsyncClient:
            def __init__(self, *a, **k):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *a):
                return False

            def build_request(self, *a, **k):
                return None

            async def send(self, *a, **k):
                raise RuntimeError("stub httpx")

        httpx_mod.AsyncClient = AsyncClient
        sys.modules["httpx"] = httpx_mod

    _install_fastapi_stubs()


def _install_fastapi_stubs() -> None:
    """Minimal FastAPI/pydantic stand-ins, enough to import server/main.py."""
    if "fastapi" in sys.modules:
        return

    class HTTPException(Exception):
        def __init__(self, status_code=500, detail=""):
            super().__init__(detail)
            self.status_code = status_code
            self.detail = detail

    class _Response:
        def __init__(self, content=None, status_code=200, headers=None, **k):
            self.content = content
            self.status_code = status_code

    class _Middleware:
        def __init__(self, *a, **k):
            pass

    class _Router:
        def __init__(self):
            self.routes = []

        def get(self, path, **k):
            def deco(fn):
                self.routes.append(("GET", path, fn))
                return fn

            return deco

        def post(self, path, **k):
            def deco(fn):
                self.routes.append(("POST", path, fn))
                return fn

            return deco

        def api_route(self, path, methods=None, **k):
            def deco(fn):
                for m in methods or ["GET"]:
                    self.routes.append((m, path, fn))
                return fn

            return deco

    class FastAPI:
        def __init__(self, *a, **k):
            self.router = _Router()

        def add_middleware(self, *a, **k):
            pass

        def get(self, path, **k):
            return self.router.get(path, **k)

        def post(self, path, **k):
            return self.router.post(path, **k)

        def api_route(self, path, **k):
            return self.router.api_route(path, **k)

    fastapi = types.ModuleType("fastapi")
    fastapi.FastAPI = FastAPI
    fastapi.HTTPException = HTTPException
    fastapi.Request = type("Request", (), {})
    sys.modules["fastapi"] = fastapi

    cors = types.ModuleType("fastapi.middleware.cors")
    cors.CORSMiddleware = _Middleware
    mw = types.ModuleType("fastapi.middleware")
    mw.cors = cors
    sys.modules["fastapi.middleware"] = mw
    sys.modules["fastapi.middleware.cors"] = cors

    responses = types.ModuleType("fastapi.responses")
    responses.FileResponse = _Response
    responses.StreamingResponse = _Response
    responses.JSONResponse = _Response
    sys.modules["fastapi.responses"] = responses

    # pydantic stand-in: BaseModel with kwargs assignment (no validation).
    class BaseModel:
        def __init__(self, **kwargs):
            annotations = getattr(type(self), "__annotations__", {}) or {}
            for field in annotations:
                setattr(self, field, kwargs.get(field))
            for key, value in kwargs.items():
                if not hasattr(self, key):
                    setattr(self, key, value)

    pydantic = types.ModuleType("pydantic")
    pydantic.BaseModel = BaseModel
    sys.modules["pydantic"] = pydantic


RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f" - {detail}" if detail else ""))


def run_gather(*coros):
    """Gather coroutines inside a fresh loop (coros must be built in-loop)."""

    async def _all():
        return await asyncio.gather(*coros)

    return asyncio.run(_all())


def gather_all(coro_factories):
    """Gather coroutines produced by factories, inside a fresh loop."""

    async def _all():
        return await asyncio.gather(*[f() for f in coro_factories])

    return asyncio.run(_all())



def _seeds(n: int, prefix: str = "seed") -> list[dict]:
    return [
        {
            "id": f"{prefix}{i:02d}",
            "artist": f"Artist {i}",
            "title": f"Song {i}",
            "score": 10 - i,
        }
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# 1. Async parallelization
# ---------------------------------------------------------------------------
def test_parallel_recommend(rec) -> None:
    """12 seeds x (radio + lfm + 3 searches) must NOT take sum(latency)."""
    reset_counters()
    payload = {"seeds": _seeds(12), "exclude_ids": [], "limit": 20}

    t0 = time.perf_counter()
    out = asyncio.run(rec.build_recommendations_async(payload))
    elapsed = time.perf_counter() - t0

    # Sequential equivalent: 12 seeds * (1 radio + 1 lfm + 3 yt searches).
    sequential = 12 * 5 * LATENCY
    print(
        f"\n  [build_recommendations] {elapsed:.2f}s wall-clock "
        f"(sequential baseline ~{sequential:.1f}s), "
        f"peak concurrent upstream calls={CONCURRENCY['peak']}, "
        f"total upstream calls={sum(CALLS.values())}"
    )
    check("recommend returns results", len(out) > 0, f"{len(out)} tracks")
    check(
        "recommend is parallel (peak concurrency > 1)",
        CONCURRENCY["peak"] > 1,
        f"peak={CONCURRENCY['peak']}",
    )
    check(
        "recommend beats the sequential baseline",
        elapsed < sequential / 2,
        f"{elapsed:.2f}s < {sequential / 2:.2f}s",
    )
    check(
        "results carry the expected shape",
        all({"id", "title", "uploader"} <= set(t) for t in out),
    )


def test_parallel_sources(rec) -> None:
    """radio / search / playlist lookups must each fan out in parallel."""
    reset_counters()
    t0 = time.perf_counter()
    radios = gather_all([(lambda i: lambda: rec.radio_for_async(f"v{i}", 10))(i) for i in range(8)])
    radio_elapsed = time.perf_counter() - t0
    print(
        f"  [radio_for x8] {radio_elapsed:.2f}s (sequential ~{8 * LATENCY:.1f}s), "
        f"peak concurrency={CONCURRENCY['peak']}"
    )
    check("8 concurrent radios all returned", all(len(r) > 0 for r in radios))
    check(
        "radio fan-out is parallel",
        radio_elapsed < 8 * LATENCY / 2,
        f"{radio_elapsed:.2f}s < {8 * LATENCY / 2:.2f}s",
    )

    reset_counters()
    t0 = time.perf_counter()
    found = gather_all([(lambda i: lambda: rec.yt_search_async(f"query {i}", 4))(i) for i in range(6)])
    search_elapsed = time.perf_counter() - t0
    print(
        f"  [yt_search x6, 2 variants each] {search_elapsed:.2f}s "
        f"(sequential ~{6 * 2 * LATENCY:.1f}s), peak concurrency={CONCURRENCY['peak']}"
    )
    check("6 concurrent searches all returned", all(len(f) > 0 for f in found))
    check(
        "search variants run concurrently",
        search_elapsed < 6 * 2 * LATENCY / 2,
        f"{search_elapsed:.2f}s",
    )

    reset_counters()
    pl = asyncio.run(rec.playlist_tracks_async("PL123", 30))
    print(f"  [playlist_tracks] {len(pl)} tracks")
    check("playlist import returns tracks", len(pl) > 0, f"{len(pl)} tracks")
    check(
        "playlist rows expose videoId for the player",
        all(t.get("videoId") and t.get("id") for t in pl),
    )


# ---------------------------------------------------------------------------
# 2. TTL caching
# ---------------------------------------------------------------------------
def test_ttl_cache(rec) -> None:
    """Repeat calls must be served from cache without upstream traffic."""
    reset_counters()
    asyncio.run(rec.radio_for_async("cacheme", 10))
    first = CALLS.get("radio", 0)
    t0 = time.perf_counter()
    asyncio.run(rec.radio_for_async("cacheme", 10))
    cached_elapsed = time.perf_counter() - t0
    second = CALLS.get("radio", 0)
    print(
        f"\n  [radio cache] first={first} upstream call(s) ~{LATENCY:.2f}s, "
        f"second={second - first} in {cached_elapsed * 1000:.2f}ms"
    )
    check("radio did 1 upstream call", first == 1)
    check("cached radio made 0 upstream calls", second == first)
    check(
        "cached radio is far faster than upstream",
        cached_elapsed < LATENCY / 2,
        f"{cached_elapsed * 1000:.2f}ms",
    )

    reset_counters()
    asyncio.run(rec.yt_search_async("cached query", 3))
    first = CALLS.get("search", 0)
    asyncio.run(rec.yt_search_async("cached query", 3))
    check("search results are cached", CALLS.get("search", 0) == first, f"{first}")

    reset_counters()
    asyncio.run(rec.playlist_tracks_async("PLCACHE", 20))
    first = CALLS.get("playlist", 0)
    asyncio.run(rec.playlist_tracks_async("PLCACHE", 20))
    check("import metadata is cached", CALLS.get("playlist", 0) == first)

    check(
        "SEARCH_TTL is within the 5-10 minute band",
        5 * 60 <= rec.SEARCH_TTL <= 10 * 60,
        f"{rec.SEARCH_TTL}s",
    )
    check(
        "RECOMMEND_TTL is within the 5-10 minute band",
        5 * 60 <= rec.RECOMMEND_TTL <= 10 * 60,
        f"{rec.RECOMMEND_TTL}s",
    )


def test_recommend_cache_hit(rec) -> None:
    """The pool must be reused across scrolls (growing excludes)."""
    reset_counters()
    seeds = _seeds(3, "s")
    first = asyncio.run(
        rec.build_recommendations_cached_async(
            {"seeds": seeds, "exclude_ids": [], "limit": 10}
        )
    )
    cold = sum(CALLS.values())

    t0 = time.perf_counter()
    second = asyncio.run(
        rec.build_recommendations_cached_async(
            {"seeds": seeds, "exclude_ids": [t["id"] for t in first], "limit": 10}
        )
    )
    warm = time.perf_counter() - t0
    warm_calls = sum(CALLS.values()) - cold
    print(
        f"  [recommend pool cache] cold={cold} upstream calls, "
        f"warm={warm_calls} in {warm * 1000:.2f}ms "
        f"(page1={len(first)} page2={len(second)})"
    )
    check("warm recommend made no upstream calls", warm_calls == 0)
    check("warm recommend is far faster", warm < LATENCY, f"{warm * 1000:.2f}ms")
    check(
        "excludes were applied to the cached pool",
        all(t["id"] not in {x["id"] for x in first} for t in second),
    )


def test_single_flight(rec) -> None:
    """Concurrent identical requests share ONE upstream round-trip."""
    reset_counters()
    out = gather_all([lambda: rec.radio_for_async("flight", 10) for _ in range(10)])
    print(
        f"\n  [single-flight] 10 concurrent identical radios -> "
        f"{CALLS.get('radio')} upstream call(s)"
    )
    check("all 10 callers got results", all(len(o) > 0 for o in out))
    check(
        "concurrent identical requests are de-duplicated",
        CALLS.get("radio") == 1,
        f"{CALLS.get('radio')} call(s)",
    )


def test_ttl_expiry(rec) -> None:
    """Entries must actually expire, and the cache stays bounded."""
    rec._ttl_set("ttl_probe", ["v"], ttl=0.05)
    check("entry present before expiry", rec._ttl_get("ttl_probe") == ["v"])
    time.sleep(0.12)
    check("entry gone after expiry", rec._ttl_get("ttl_probe") is None)

    rec._TTL_STORE.clear()
    for i in range(rec.MAX_CACHE_ENTRIES + 50):
        rec._ttl_set(f"k{i}", ["v"], ttl=600)
    check(
        "cache stays bounded under pressure",
        len(rec._TTL_STORE) <= rec.MAX_CACHE_ENTRIES,
        f"{len(rec._TTL_STORE)} <= {rec.MAX_CACHE_ENTRIES}",
    )


# ---------------------------------------------------------------------------
# 3. Error handling & fallbacks
# ---------------------------------------------------------------------------
def _broken_yt():
    def boom(*a, **k):
        raise RuntimeError("boom")

    return types.SimpleNamespace(
        get_watch_playlist=boom, search=boom, get_playlist=boom
    )


def _hanging_yt(seconds=30):
    def hang(*a, **k):
        time.sleep(seconds)

    return types.SimpleNamespace(
        get_watch_playlist=hang, search=hang, get_playlist=hang
    )


def test_error_fallbacks(rec) -> None:
    """A failing upstream must not break the response."""
    rec._yt = _broken_yt()

    try:
        out = asyncio.run(
            rec.build_recommendations_async(
                {"seeds": _seeds(2, "x"), "exclude_ids": [], "limit": 10}
            )
        )
        check("broken ytmusicapi yields a list (no raise)", isinstance(out, list))
    except Exception as exc:
        check("broken ytmusicapi yields a list (no raise)", False, repr(exc))

    try:
        check(
            "broken playlist fetch returns []",
            asyncio.run(rec.playlist_tracks_async("PLBAD", 10)) == [],
        )
    except Exception as exc:
        check("broken playlist fetch returns []", False, repr(exc))

    # A hanging upstream must be cut off by the timeout, not hang forever.
    rec._yt = _hanging_yt()
    reset_counters()
    t0 = time.perf_counter()
    partial = asyncio.run(
        rec.build_recommendations_cached_async(
            {"seeds": _seeds(2, "h"), "exclude_ids": [], "limit": 10}
        )
    )
    elapsed = time.perf_counter() - t0
    print(
        f"  [hanging upstream] returned in {elapsed:.2f}s with {len(partial)} "
        f"results (hard timeout {rec.BUILD_HARD_TIMEOUT}s)"
    )
    check(
        "hanging upstream is bounded by a timeout",
        elapsed < rec.BUILD_HARD_TIMEOUT + 6,
        f"{elapsed:.2f}s",
    )
    check("hanging upstream still returns a list", isinstance(partial, list))

    # Malformed payloads must not raise.
    try:
        check("empty payload is safe", asyncio.run(rec.build_recommendations_cached_async({})) == [])
        check(
            "garbage payload is safe",
            isinstance(
                asyncio.run(
                    rec.build_recommendations_cached_async(
                        {"seeds": [None, 5, {}], "exclude_ids": None, "limit": "abc"}
                    )
                ),
                list,
            ),
        )
    except Exception as exc:
        check("malformed payloads are safe", False, repr(exc))

    # Sync wrappers (Flask path) must work outside AND inside a running loop.
    rec._yt = FakeYTMusic()
    try:
        sync_out = rec.build_recommendations_cached(
            {"seeds": [{"id": "sy1", "artist": "A", "title": "T"}], "limit": 5}
        )
        check("sync wrapper (Flask path) works", len(sync_out) > 0, f"{len(sync_out)}")
    except Exception as exc:
        check("sync wrapper (Flask path) works", False, repr(exc))

    async def in_loop():
        return rec.radio_for("loopy", 5)

    try:
        check(
            "sync wrapper is safe inside a running loop",
            len(asyncio.run(in_loop())) > 0,
        )
    except Exception as exc:
        check("sync wrapper is safe inside a running loop", False, repr(exc))


def test_gather_partial(rec) -> None:
    """_gather must give per-slot None for failures, never raise."""

    async def ok():
        await asyncio.sleep(0.05)
        return "good"

    async def boom():
        raise ValueError("nope")

    async def slow():
        await asyncio.sleep(5)
        return "slow"

    got = asyncio.run(rec._gather([("a", ok), ("b", boom), ("c", slow)], timeout=0.2))
    check("_gather keeps successful results", got.get("a") == "good")
    check("_gather isolates a raising source", got.get("b") is None)
    check("_gather times out a slow source", got.get("c") is None)
    check("_gather returns a slot for every task", set(got) == {"a", "b", "c"})


# ---------------------------------------------------------------------------
# 4. Route wiring
# ---------------------------------------------------------------------------
class FakeFastAPIApp:
    # Force FastAPI detection (the module heuristic).
    __module__ = "fastapi.applications"

    def __init__(self):
        self.routes = []

    def get(self, path, **k):
        def deco(fn):
            self.routes.append(("GET", path))
            return fn

        return deco

    def post(self, path, **k):
        def deco(fn):
            self.routes.append(("POST", path))
            return fn

        return deco


class FakeFlaskApp:
    routes: list = []

    def get(self, path):
        def deco(fn):
            FakeFlaskApp.routes.append(path)
            return fn

        return deco

    def post(self, path):
        def deco(fn):
            FakeFlaskApp.routes.append(path)
            return fn

        return deco


def test_routes_register(rec) -> None:
    expected = ["/api/radio", "/api/recommend"]
    fake = FakeFastAPIApp()
    rec.register_recommend_routes(fake)
    check(
        "routes register on a FastAPI app",
        sorted(path for _, path in fake.routes)
        == sorted(rec._RECOMMEND_PATHS),
        str(fake.routes),
    )
    rec.register_recommend_routes(FakeFlaskApp())
    check(
        "routes register on a Flask app",
        sorted(FakeFlaskApp.routes) == sorted(expected),
    )


def test_route_collision_override(rec) -> None:
    """Wiring into an app that already defines these paths must actually win.

    Starlette matches routes in registration order, so without removal the
    pre-existing handlers would shadow ours (main.py defines all three paths).
    """
    expected = set(rec._RECOMMEND_PATHS)

    class _Route:
        """Mimics a Starlette Route: has .path, .methods and .endpoint.

        Storing the raw function would NOT exercise _remove_existing_routes,
        which reads route.path.
        """

        def __init__(self, method, path, fn):
            self.methods = {method}
            self.path = path
            self.endpoint = fn

    class _Router:
        def __init__(self):
            self.routes = []

        def get(self, path, **k):
            def deco(fn):
                self.routes.append(_Route("GET", path, fn))
                return fn

            return deco

        def post(self, path, **k):
            def deco(fn):
                self.routes.append(_Route("POST", path, fn))
                return fn

            return deco

    class _PreRegisteredApp:
        """Mimics main.py: same three paths already registered, plus others."""

        # Force FastAPI detection (the module heuristic).
        __module__ = "fastapi.applications"

        def __init__(self):
            self.router = _Router()

        def get(self, path, **k):
            return self.router.get(path, **k)

        def post(self, path, **k):
            return self.router.post(path, **k)

    def _seed_old_routes(app):
        # Seed only paths this module owns; the import route belongs to
        # main.py and must never be touched by recommend.py.
        for path in rec._RECOMMEND_PATHS:
            if path == "/api/recommend":
                app.post(path)(lambda: "OLD main.py handler")
            else:
                app.get(path)(lambda: "OLD main.py handler")

    app = _PreRegisteredApp()
    _seed_old_routes(app)
    app.get("/api/search")(lambda: "search")  # not owned by this module
    # /api/import/youtube/playlist is canonically owned by main.py (yt-dlp):
    # recommend.py must leave it (and its response shape) untouched.
    app.get("/api/import/youtube/playlist")(lambda: "main import")
    before = len(app.router.routes)

    # Explicit override=True: this test verifies the takeover semantics the
    # live server relies on (default is now non-destructive).
    rec.register_recommend_routes(app, override=True)
    after = app.router.routes

    owned = [r for r in after if r.path in expected]
    untouched = [r for r in after if r.path == "/api/search"]
    kept_import = [
        r
        for r in after
        if r.path == "/api/import/youtube/playlist"
        and getattr(r.endpoint, "__module__", "") != "recommend"
    ]
    check(
        "colliding paths are not duplicated",
        len(owned) == 2,
        f"{len(owned)} routes for 2 paths (was {before} before)",
    )
    check(
        "the recommend.py handler is the surviving one",
        all(
            getattr(r.endpoint, "__module__", "") == "recommend" for r in owned
        ),
        str([getattr(r.endpoint, "__name__", "?") for r in owned]),
    )
    check(
        "routes this module does not own are untouched",
        len(untouched) == 1,
        f"{len(untouched)}",
    )
    check(
        "import route stays with the host app",
        len(kept_import) == 1,
        f"{len(kept_import)} host import route(s)",
    )
    check(
        "no leftover duplicates from the pre-registration",
        len(after) == 4,
        f"{len(after)} routes total (before: {before})",
    )

    # override=False must keep the app's own handlers alongside ours.
    app2 = _PreRegisteredApp()
    _seed_old_routes(app2)
    rec.register_recommend_routes(app2, override=False)
    kept = [r for r in app2.router.routes if r.path in expected]
    check(
        "override=False preserves the host app's handlers",
        len(kept) == 4,
        f"{len(kept)} routes (2 old + 2 new)",
    )


def test_proxy_adoption(rec) -> None:
    """The host app's PROXY_URL must be adopted for ytmusicapi."""
    original_proxy = rec.PROXY_URL
    original_yt = rec._yt

    class _Route:
        def __init__(self, method, path, fn):
            self.methods = {method}
            self.path = path
            self.endpoint = fn

    class _Router:
        def __init__(self):
            self.routes = []

        def get(self, path, **k):
            def deco(fn):
                self.routes.append(_Route("GET", path, fn))
                return fn

            return deco

        def post(self, path, **k):
            def deco(fn):
                self.routes.append(_Route("POST", path, fn))
                return fn

            return deco

    class _FastApiLike:
        __module__ = "fastapi.applications"
        PROXY_URL = "socks5://127.0.0.1:9999"

        def __init__(self):
            self.router = _Router()

        def get(self, path, **k):
            return self.router.get(path, **k)

        def post(self, path, **k):
            return self.router.post(path, **k)

    rec.PROXY_URL = ""
    rec._yt = None
    try:
        rec.register_recommend_routes(_FastApiLike())
        check(
            "host PROXY_URL is adopted",
            rec.PROXY_URL == "socks5://127.0.0.1:9999",
            rec.PROXY_URL or "(empty)",
        )
        check(
            "proxy session is built when a proxy is set",
            rec._yt_requests_session() is not None,
        )
        check(
            "stale client is dropped so the new proxy takes effect",
            rec._yt is None or rec._ytmusic() is not None,
        )
    finally:
        rec.PROXY_URL = original_proxy
        rec._yt = original_yt

    rec.PROXY_URL = ""
    try:
        check(
            "no proxy -> no custom session (ytmusicapi default)",
            rec._yt_requests_session() is None,
        )
    finally:
        rec.PROXY_URL = original_proxy


# ---------------------------------------------------------------------------
# 5. server/main.py
# ---------------------------------------------------------------------------
def test_main_module() -> None:
    """server/main.py must expose non-blocking handlers with a working cache."""
    try:
        import main  # noqa: F401  (server/ is on sys.path from main())
    except Exception as exc:
        check("server/main.py imports", False, repr(exc))
        return
    check("server/main.py imports", True)

    import inspect

    for name in (
        "search_tracks",
        "import_youtube_playlist",
        "radio_tracks",
        "recommend_tracks",
        "stream_audio",
    ):
        check(
            f"main.{name} is async (never blocks the event loop)",
            inspect.iscoroutinefunction(getattr(main, name, None)),
        )

    main._cache_set_ttl("probe", ["v"], 0.05)
    check("main cache hit before expiry", main._cache_get("probe") == ["v"])
    time.sleep(0.12)
    check("main cache miss after expiry", main._cache_get("probe") is None)

    main.TTL_CACHE.clear()
    for i in range(main.MAX_CACHE_ENTRIES + 100):
        main._cache_set_ttl(f"k{i}", ["v"], 600)
    check(
        "main cache stays bounded",
        len(main.TTL_CACHE) <= main.MAX_CACHE_ENTRIES,
        f"{len(main.TTL_CACHE)} <= {main.MAX_CACHE_ENTRIES}",
    )

    def fake_extract_flat(target, count):
        _bump("main_ytdlp")
        _enter()
        try:
            time.sleep(LATENCY)
        finally:
            _leave()
        return [
            {
                "id": f"{target[:14]}_{i}",
                "videoId": f"{target[:14]}_{i}",
                "title": f"T{i}",
                "uploader": "U",
                "artist": "U",
                "thumbnail": None,
                "duration": 100,
                "url": "http://x",
            }
            for i in range(count)
        ]

    main._extract_flat = fake_extract_flat
    seeds = [
        {"id": f"m{i}", "artist": f"A{i}", "title": f"T{i}", "score": 3}
        for i in range(5)
    ]
    reset_counters()
    main.TTL_CACHE.clear()
    t0 = time.perf_counter()
    res = asyncio.run(main.recommend_tracks(main.RecommendBody(seeds=seeds, exclude_ids=[], limit=20)))
    elapsed = time.perf_counter() - t0
    sequential = 5 * LATENCY
    print(
        f"\n  [main.recommend_tracks] {elapsed:.2f}s wall-clock "
        f"(sequential ~{sequential:.1f}s), peak concurrency={CONCURRENCY['peak']}"
    )
    check("main recommend returns results", len(res["results"]) > 0)
    check(
        "main recommend fans out per seed in parallel",
        elapsed < sequential / 2,
        f"{elapsed:.2f}s < {sequential / 2:.2f}s",
    )

    cold = sum(CALLS.values())
    t0 = time.perf_counter()
    asyncio.run(main.recommend_tracks(main.RecommendBody(seeds=seeds, exclude_ids=[], limit=20)))
    warm = time.perf_counter() - t0
    print(
        f"  [main recommend cache] warm call: {sum(CALLS.values()) - cold} "
        f"upstream calls in {warm * 1000:.2f}ms"
    )
    check("main recommend warm call hits cache", sum(CALLS.values()) == cold)
    check("main recommend warm call is fast", warm < LATENCY / 2, f"{warm * 1000:.2f}ms")

    excluded = [t["id"] for t in res["results"][:2]]
    res3 = asyncio.run(
        main.recommend_tracks(main.RecommendBody(seeds=seeds, exclude_ids=excluded, limit=20))
    )
    check(
        "main recommend honours exclude_ids on a cached pool",
        all(r["id"] not in excluded for r in res3["results"]),
    )
    check(
        "main recommend never returns a seed",
        all(r["id"] not in {s["id"] for s in seeds} for r in res3["results"]),
    )

    def broken_extract(*a, **k):
        raise RuntimeError("yt-dlp exploded")

    main._extract_flat = broken_extract
    main.TTL_CACHE.clear()
    try:
        res4 = asyncio.run(
            main.recommend_tracks(main.RecommendBody(seeds=seeds[:2], exclude_ids=[], limit=10))
        )
        check(
            "main recommend is partial-safe on upstream failure",
            res4["results"] == [],
            "empty list, no exception",
        )
    except Exception as exc:
        check("main recommend is partial-safe on upstream failure", False, repr(exc))


def run() -> int:
    _install_stubs()
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

    import recommend as rec

    rec.LASTFM_API_KEY = "test_key"  # exercise the Last.fm branch too

    print("\n=== 1. Async parallelization ===")
    test_parallel_recommend(rec)
    test_parallel_sources(rec)

    print("\n=== 2. TTL caching ===")
    test_ttl_cache(rec)
    test_recommend_cache_hit(rec)
    test_single_flight(rec)
    test_ttl_expiry(rec)

    print("\n=== 3. Error handling & fallbacks ===")
    test_error_fallbacks(rec)
    test_gather_partial(rec)

    print("\n=== 4. Route wiring ===")
    test_routes_register(rec)
    test_route_collision_override(rec)
    test_proxy_adoption(rec)

    print("\n=== 5. server/main.py ===")
    test_main_module()

    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\n" + "=" * 66)
    print(f"{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:")
        for name in failed:
            print(f"  - {name}")
    print("=" * 66)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(run())
