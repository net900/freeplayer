#!/usr/bin/env python3
"""SourceProtocol v1 自检工具（仅标准库，语言无关）。

用法：
    python docs/source-dev/protocol_check.py --base http://127.0.0.1:8790
    python docs/source-dev/protocol_check.py \
        --sources-url http://127.0.0.1:8790/v1/xxx/sources_test.php
    python docs/source-dev/protocol_check.py --base http://host --q 示例 --source demo

它会读取源 manifest 里的 endpoints 映射；未映射的动作使用默认路径。
只做只读检查，不会写入或修改源。
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_ENDPOINTS = {
    "ui": "/v1/{source_id}/ui",
    "feed": "/v1/{source_id}/feed",
    "search": "/v1/{source_id}/search",
    "detail": "/v1/{source_id}/detail/{item_id}",
    "episodes": "/v1/{source_id}/episodes/{item_id}",
    "play": "/v1/{source_id}/play",
}

KNOWN_PAGES = {
    "home.feed", "search", "list.rank", "list.new", "list.category", "detail",
    "library.history", "library.follow", "library.reservations", "library.likes",
    "library.favorites", "library.downloads", "player",
}


class Checker:
    def __init__(self, base: str, sources_url: str, query: str, source_id: str):
        self.base = base.rstrip("/")
        self.sources_url = sources_url
        self.query = query
        self.want_source = source_id
        self.fails = 0
        self.source_id = ""
        self.endpoints: dict[str, str] = {}

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"PASS  {name:<24} {detail}")
        else:
            self.fails += 1
            print(f"FAIL  {name:<24} {detail}")

    def request(self, method: str, url: str, body: dict | None = None):
        data = None
        headers = {
            "X-Client-Id": "protocol-check",
            "X-Source-Protocol": "1",
            "Accept": "application/json",
        }
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            status = exc.code
        except urllib.error.URLError as exc:
            return 0, {}, str(exc).encode()
        try:
            envelope = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return status, {}, raw
        return status, envelope, raw

    def fill(self, key: str, item_id: str = "") -> str:
        template = self.endpoints.get(key) or DEFAULT_ENDPOINTS[key]
        path = (
            template
            .replace("{source_id}", urllib.parse.quote(self.source_id))
            .replace("{sid}", urllib.parse.quote(self.source_id))
            .replace("{item_id}", urllib.parse.quote(item_id))
            .replace("{album_id}", urllib.parse.quote(item_id))
        )
        if path.startswith("http://") or path.startswith("https://"):
            return path
        if not path.startswith("/"):
            path = "/" + path
        return self.base + path

    def run(self) -> int:
        sources_url = self.sources_url or (self.base + "/v1/sources")
        status, env, _ = self.request("GET", sources_url)
        ok = env.get("code") == 0 and isinstance(env.get("data"), dict)
        sources = env.get("data", {}).get("sources", []) if ok else []
        self.check("sources", ok and len(sources) > 0,
                   f"HTTP {status}, {len(sources)} source(s)")
        if not sources:
            return self.finish()

        chosen = None
        for source in sources:
            if self.want_source and source.get("id") == self.want_source:
                chosen = source
                break
        chosen = chosen or sources[0]
        self.source_id = chosen.get("id", "")
        self.endpoints = chosen.get("endpoints") or {}
        self.check("protocol", chosen.get("protocol") == "1",
                   f"id={self.source_id} protocol={chosen.get('protocol')}")

        # UI
        pages = ",".join(sorted(KNOWN_PAGES))
        status, env, _ = self.request("GET", self.fill("ui"))
        nav_pages = []
        if env.get("code") == 0:
            for group in env.get("data", {}).get("navigation", []):
                for item in group.get("items", []):
                    nav_pages.append(item.get("page", ""))
        ui_ok = (
            env.get("code") == 0
            and env.get("data", {}).get("default_page")
            and all(page in KNOWN_PAGES for page in nav_pages if page)
        )
        self.check("ui manifest", bool(ui_ok),
                   f"pages={len(nav_pages)}, HTTP {status}")

        # Feed
        status, env, _ = self.request("GET", self.fill("feed") + "?limit=2")
        items = env.get("data", {}).get("items", []) if env.get("code") == 0 else []
        self.check("feed", len(items) > 0, f"{len(items)} item(s)")
        if not items:
            return self.finish()
        item = items[0]
        item_id = item.get("id") or item.get("item_id") or ""

        # Search
        if self.query:
            url = self.fill("search") + "?" + urllib.parse.urlencode(
                {"q": self.query, "limit": "5"}
            )
            _, env, _ = self.request("GET", url)
            found = env.get("data", {}).get("items", []) if env.get("code") == 0 else []
            self.check("search", len(found) > 0, f"q={self.query!r}, {len(found)} item(s)")

        # Detail
        status, env, _ = self.request("GET", self.fill("detail", item_id))
        self.check("detail", env.get("code") == 0, f"id={item_id}, HTTP {status}")

        # Episodes
        status, env, _ = self.request("GET", self.fill("episodes", item_id))
        episodes = env.get("data", {}).get("items", []) if env.get("code") == 0 else []
        self.check("episodes", len(episodes) > 0, f"{len(episodes)} episode(s)")
        if not episodes:
            return self.finish()
        episode_id = episodes[0].get("id") or episodes[0].get("episode_id") or ""

        # Play
        status, env, _ = self.request(
            "POST",
            self.fill("play"),
            {"item_id": item_id, "episode_id": episode_id, "quality": "auto"},
        )
        streams = env.get("data", {}).get("streams", []) if env.get("code") == 0 else []
        url = streams[0].get("url", "") if streams else ""
        self.check("play", bool(url), f"{len(streams)} stream(s)")
        if not url:
            return self.finish()

        # Asset Range
        req = urllib.request.Request(url, headers={"Range": "bytes=0-255"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                head = resp.read(12)
                status = resp.status
                content_range = resp.headers.get("Content-Range", "")
        except urllib.error.HTTPError as exc:
            status, head, content_range = exc.code, b"", ""
        asset_ok = (
            status == 206
            and bool(content_range)
            and len(head) >= 8
            and head[4:8] == b"ftyp"
        )
        self.check("asset range", asset_ok,
                   f"HTTP {status}, head={head[:12].hex()}")

        # Error envelope
        _, env, _ = self.request(
            "GET", self.fill("detail", "not-a-real-id")
        )
        self.check("error envelope", env.get("code") == 40400,
                   f"code={env.get('code')}")

        return self.finish()

    def finish(self) -> int:
        if self.fails:
            print(f"\n{self.fails} check(s) failed")
            return 1
        print("\nSourceProtocol v1 checks passed")
        return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="SourceProtocol v1 self-check")
    parser.add_argument("--base", default="",
                        help="gateway origin; derived from --sources-url when omitted")
    parser.add_argument("--sources-url", default="",
                        help="exact source-list URL (overrides --base + /v1/sources)")
    parser.add_argument("--q", default="", help="search query; skipped when empty")
    parser.add_argument("--source", default="", help="source id; first when empty")
    args = parser.parse_args()
    base = args.base
    if not base and args.sources_url:
        parsed = urllib.parse.urlparse(args.sources_url)
        base = f"{parsed.scheme}://{parsed.netloc}"
    if not base:
        base = "http://127.0.0.1:8790"
    sys.exit(Checker(base, args.sources_url, args.q, args.source).run())


if __name__ == "__main__":
    main()
