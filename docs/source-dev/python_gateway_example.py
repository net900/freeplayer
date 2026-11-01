#!/usr/bin/env python3
"""最小可运行的 SourceProtocol v1 网关示例（仅标准库）。

用途
----
给非 Go 开发者一个可以照着改的骨架：任何语言只要实现下面这些 HTTP 端点，
客户端就能把它当成一个可浏览、可搜索、可播放的内容源。

运行
----
    # 1) 准备一个竖屏 MP4（或任何 mp4）
    #    默认读取同目录下的 sample.mp4，也可以用 FP_MEDIA_FILE 指定
    # 2) 启动
    python docs/source-dev/python_gateway_example.py

环境变量
--------
    FP_LISTEN       监听地址，默认 127.0.0.1:8790
    FP_MEDIA_FILE   本地 mp4 路径，默认 ./sample.mp4
    FP_MEDIA_URL    可选：改为代理一个上游 URL（优先于 FP_MEDIA_FILE）
    FP_ASSET_SECRET asset token 的 HMAC 密钥，默认仅用于本地演示

这个示例只做“明文 MP4 + Range”。加密媒体的服务端解密由 Go 网关的
internal/asset + internal/media/cenc 完成；协议字段见 docs/SOURCE_DEVELOPMENT.md。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOURCE_ID = "demo"
SOURCE_NAME = "示例源"
ASSET_SECRET = os.environ.get("FP_ASSET_SECRET", "dev-only-change-me").encode()
MEDIA_FILE = os.environ.get("FP_MEDIA_FILE", "sample.mp4")
MEDIA_URL = os.environ.get("FP_MEDIA_URL", "")
PAGE_TYPES = {
    "home.feed", "search", "list.rank", "list.new", "list.category", "detail",
    "library.history", "library.follow", "library.reservations", "library.likes",
    "library.favorites", "library.downloads", "player",
}

# 演示用的服务端会话与 token：真实源可以只保留服务端会话，也可以把
# token 放进登录响应的 credentials 里，让客户端用于后续校验/直连。
SESSION = {"logged_in": False, "name": "", "user_id": ""}
TOKENS: set[str] = set()

# --------------------------------------------------------------------------
# 示例数据：全部为虚构内容
# --------------------------------------------------------------------------

ITEMS = [
    {
        "id": "demo-1",
        "title": "示例剧集：第一季",
        "description": "用于演示详情、选集与播放链路。",
        "tags": ["示例", "剧情"],
        "badges": ["示例"],
        "episodes": 3,
        "heat": 12000,
        "follows": 3400,
        "plays": 56000,
    },
    {
        "id": "demo-2",
        "title": "样例剧场：夏日来信",
        "description": "演示搜索、榜单与分类。",
        "tags": ["示例", "都市"],
        "badges": [],
        "episodes": 3,
        "heat": 8600,
        "follows": 2100,
        "plays": 33000,
    },
    {
        "id": "demo-3",
        "title": "虚构故事：夜航",
        "description": "演示信息流连续滑动。",
        "tags": ["示例", "悬疑"],
        "badges": ["新"],
        "episodes": 3,
        "heat": 5400,
        "follows": 900,
        "plays": 12000,
    },
    {
        "id": "demo-4",
        "title": "演示短剧：山与海",
        "description": "演示片库与空状态。",
        "tags": ["示例", "治愈"],
        "badges": [],
        "episodes": 3,
        "heat": 3200,
        "follows": 600,
        "plays": 8000,
    },
]


def by_id(item_id: str) -> dict | None:
    return next((item for item in ITEMS if item["id"] == item_id), None)


def episode_id(item_id: str, index: int) -> str:
    return f"{item_id}-ep{index}"


def item_json(item: dict) -> dict:
    # id 和 item_id 都写：客户端 DTO 读 id，协议读 item_id。
    return {
        "source": SOURCE_ID,
        "id": item["id"],
        "item_id": item["id"],
        "type": "series",
        "title": item["title"],
        "cover": "",
        "description": item["description"],
        "episode_count": item["episodes"],
        "tags": item["tags"],
        "badges": item["badges"],
        "extra": {
            # 首页卡片用它定位首集；不写也能用，但会多一次 episodes 请求。
            "vid": episode_id(item["id"], 1),
            "first_vid": episode_id(item["id"], 1),
            "episode_count": item["episodes"],
            "heat": item["heat"],
            "follow_count": item["follows"],
            "play_count": item["plays"],
        },
    }


def episode_json(item: dict, index: int) -> dict:
    return {
        "episode_id": episode_id(item["id"], index),
        "id": episode_id(item["id"], index),
        "index": index,
        "title": f"第 {index} 集",
        "duration_sec": 8,
        "duration_ms": 8000,
        "extra": {},
    }


def page(items: list[dict], next_cursor: str = "") -> dict:
    return {
        "items": items,
        "next": next_cursor,
        "next_cursor": next_cursor,
        "has_more": bool(next_cursor),
        "total": len(items),
    }


# --------------------------------------------------------------------------
# asset token：真实网关用 AES-GCM，这里用 HMAC 演示“URL 不透明化”
# --------------------------------------------------------------------------

def b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def b64d(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def seal(url: str, ttl_sec: int = 3600) -> str:
    payload = json.dumps({"u": url, "e": int(time.time()) + ttl_sec}).encode()
    sig = hmac.new(ASSET_SECRET, payload, hashlib.sha256).digest()[:16]
    return b64e(payload) + "." + b64e(sig)


def unseal(token: str) -> str:
    raw, sig = token.split(".", 1)
    payload = b64d(raw)
    want = hmac.new(ASSET_SECRET, payload, hashlib.sha256).digest()[:16]
    if not hmac.compare_digest(want, b64d(sig)):
        raise ValueError("bad asset signature")
    data = json.loads(payload)
    if data["e"] < time.time():
        raise ValueError("asset expired")
    return data["u"]


# --------------------------------------------------------------------------
# UI manifest
# --------------------------------------------------------------------------

def ui_manifest(client_pages: list[str]) -> dict:
    allowed = set(client_pages)

    def keep(page: str) -> bool:
        return not allowed or page in allowed

    content = []
    if keep("home.feed"):
        content.append({"title": "首页", "icon": "home", "page": "home.feed"})
    if keep("search"):
        content.append({"title": "搜索", "icon": "search", "page": "search"})
    lists = []
    if keep("list.rank"):
        lists.append({"title": "榜单", "icon": "leaderboard", "page": "list.rank"})
    if keep("list.new"):
        lists.append({"title": "新上", "icon": "fiber_new", "page": "list.new"})
    if keep("list.category"):
        lists.append({"title": "分类", "icon": "category", "page": "list.category"})
    library = []
    for title, icon, page in [
        ("历史", "history", "library.history"),
        ("收藏", "favorite", "library.favorites"),
        ("下载", "download", "library.downloads"),
    ]:
        if keep(page):
            library.append({"title": title, "icon": icon, "page": page})

    navigation = []
    if content:
        navigation.append({"title": "内容", "icon": "home", "items": content})
    if lists:
        navigation.append({"title": "发现", "icon": "compass", "items": lists})
    if library:
        navigation.append({"title": "片库", "icon": "video_library", "items": library})

    return {
        "ui_version": 1,
        "default_page": "home.feed" if keep("home.feed") else "search",
        "theme": {"seed": "#3B6CF6", "mode": "auto"},
        "navigation": navigation,
        "home_tabs": [
            {"key": "home", "title": "精选", "channel": "home"},
            {"key": "series", "title": "连载", "channel": "series",
             "category_tag": "示例分类"},
            {"key": "mine", "title": "我的追更", "channel": "following",
             "requires_auth": True},
        ],
        "labels": {
            "play": "播放",
            "play_full": "观看完整剧集 · 全{count}集",
            "home.login_required_title": "需要登录",
            "home.login_required_body": "登录后查看这里的内容。",
            "home.login_action": "登录",
            "detail.hot_label": "热度",
            "detail.follows_label": "追剧",
            "detail.plays_label": "播放",
            "detail.tab.episodes": "选集",
            "detail.tab.series": "系列",
            "detail.tab.reviews": "剧评",
            "detail.tab.related": "相关",
            "new.tab.recommend": "最新",
            "new.tab.calendar": "日历",
            "new.gender.all": "全部",
            "new.gender.male": "男频",
            "new.gender.female": "女频",
            "new.empty_day": "这一天还没有内容",
            "search.type_fallback": "内容",
            "login.title": "示例登录",
            "login.submit": "登录",
            "login.required": "{field} 不能为空",
            "login.confirmed": "登录成功",
        },
    }


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

def trace_id() -> str:
    return secrets.token_hex(8)


class Handler(BaseHTTPRequestHandler):
    server_version = "SourceProtocolDemo/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers ---------------------------------------------------------

    def send_env(self, data=None, code: int = 0, message: str = "ok") -> None:
        body = json.dumps(
            {"code": code, "message": message, "data": data, "trace_id": trace_id()},
            ensure_ascii=False,
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error_env(self, code: int, message: str) -> None:
        self.send_env(None, code=code, message=message)

    def read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def query(self) -> dict[str, list[str]]:
        return urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

    def one(self, key: str, default: str = "") -> str:
        values = self.query().get(key)
        return values[0] if values else default

    def offset(self) -> int:
        try:
            return max(0, int(self.one("cursor", "0")))
        except ValueError:
            return 0

    def limit(self) -> int:
        try:
            return max(1, min(50, int(self.one("limit", "20"))))
        except ValueError:
            return 20

    def paged(self, source: list[dict]) -> dict:
        start = self.offset()
        size = self.limit()
        chunk = source[start:start + size]
        next_cursor = str(start + size) if start + size < len(source) else ""
        return page([item_json(i) for i in chunk], next_cursor)

    # -- routing ---------------------------------------------------------

    def do_HEAD(self) -> None:
        self.route()

    def do_GET(self) -> None:
        self.route()

    def do_POST(self) -> None:
        self.route()

    def route(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        parts = [urllib.parse.unquote(p) for p in parsed.path.strip("/").split("/") if p]

        if parts == ["healthz"]:
            return self.send_env({"ok": True, "time": int(time.time())})
        if parts == ["v1", "meta"]:
            return self.send_env({
                "name": "Demo Source Gateway",
                "version": "1.0.0",
                "protocol": "1",
                "source_count": 1,
            })
        # 源列表端点也可以是任意路径：把 /v1/sources_test.php 当作入口即可。
        if parts in (["v1", "sources"], ["v1", "sources_test.php"]):
            return self.send_env({"sources": [manifest()]})
        if len(parts) >= 3 and parts[0] == "v1":
            return self.source_route(parts[1], parts[2], parts[3:])
        return self.send_error_env(40400, "not found")

    def source_route(self, sid: str, endpoint: str, rest: list[str]) -> None:
        if sid != SOURCE_ID:
            return self.send_error_env(40400, f"source not found: {sid}")
        # 任意路径示例：manifest 的 endpoints 可以把它映射到下面的逻辑动作。
        endpoint = {"ui_test.php": "ui", "feed_test.php": "feed"}.get(
            endpoint, endpoint
        )

        if endpoint == "ui":
            pages = [
                p.strip()
                for p in self.headers.get("X-Client-Pages", "").split(",")
                if p.strip()
            ]
            return self.send_env(ui_manifest(pages))

        if endpoint == "tabs":
            return self.send_env({"tabs": [
                {"key": "home", "title": "精选", "channel": "home"},
                {"key": "series", "title": "连载", "channel": "series"},
            ]})

        if endpoint == "feed":
            if self.one("channel") == "following" and not SESSION["logged_in"]:
                return self.send_error_env(40100, "login required")
            # cursor 是 offset；客户端把它当成不透明字符串。
            return self.send_env(self.paged(ITEMS))

        if endpoint == "search":
            q = self.one("q").strip().lower()
            found = [
                i
                for i in ITEMS
                if q and (q in i["title"].lower() or q in i["description"].lower())
            ]
            return self.send_env(self.paged(found))

        if endpoint == "suggest":
            q = self.one("q").strip()
            words = [i["title"] for i in ITEMS if q and q in i["title"]][:5]
            return self.send_env({"words": words, "items": []})

        if endpoint == "rank" and rest[:1] == ["meta"]:
            return self.send_env({"groups": [], "defaults": {}})

        if endpoint == "category" and rest[:1] == ["meta"]:
            return self.send_env({"groups": []})

        if endpoint in {"rank", "new", "category"}:
            return self.send_env(self.paged(ITEMS))

        if endpoint == "detail":
            if not rest:
                return self.send_error_env(40001, "item id missing")
            item = by_id(rest[0])
            if not item:
                return self.send_error_env(40400, "item not found")
            return self.send_env(item_json(item))

        if endpoint == "episodes":
            if not rest:
                return self.send_error_env(40001, "item id missing")
            item = by_id(rest[0])
            if not item:
                return self.send_error_env(40400, "item not found")
            episodes = [episode_json(item, n) for n in range(1, item["episodes"] + 1)]
            return self.send_env({
                "item_id": item["id"],
                "items": episodes,
                "episodes": episodes,
                "next": "",
                "next_cursor": "",
                "has_more": False,
            })

        if endpoint == "play":
            return self.play()

        if endpoint == "asset":
            if not rest:
                return self.send_error_env(40001, "asset id missing")
            return self.serve_asset(rest[0])

        if endpoint == "stats":
            ids = [x for x in self.one("ids").split(",") if x]
            if not ids:
                ids = [x for x in self.one("item_id").split(",") if x]
            stats = {}
            for item_id in ids[:4]:
                item = by_id(item_id)
                if item:
                    stats[item_id] = {
                        "episode_cnt": item["episodes"],
                        "episode_index": 1,
                        "play_count": item["plays"],
                        "like_count": 100,
                        "comment_count": 8,
                        "follow_count": item["follows"],
                        "favorite_count": 20,
                        "season_index": 1,
                        "multi_season": False,
                        "status": 0,
                        "duration_sec": 8,
                        "categories": item["tags"],
                        "liked": False,
                    }
            return self.send_env({"stats": stats})

        if endpoint == "comments":
            return self.send_env({"items": [], "next": "", "total": 0})
        if endpoint == "danmaku":
            return self.send_env({"items": [], "generated": True})
        if endpoint == "emoticons":
            return self.send_env([])
        if endpoint == "album":
            return self.send_env(page([]))
        if endpoint == "plan":
            return self.send_env(page([]))
        if endpoint == "auth" and rest[:1] == ["login"]:
            body = self.read_json()
            fields = body.get("fields") or {}
            username = str(fields.get("username", "")).strip()
            password = str(fields.get("password", ""))
            if not username or not password:
                return self.send_error_env(40001, "username and password are required")
            # 真实源在这里校验上游；可以返回 token 供客户端后续校验。
            token = secrets.token_hex(16)
            TOKENS.add(token)
            SESSION.update(logged_in=True, name=username, user_id=f"user-{username}")
            return self.send_env({
                "logged_in": True,
                "user_id": SESSION["user_id"],
                "name": SESSION["name"],
                "avatar": "",
                "credentials": {
                    "token": token,
                    "expires_at": int(time.time()) + 3600,
                },
            })
        if endpoint == "auth" and rest[:1] == ["me"]:
            auth = self.headers.get("Authorization", "")
            token = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
            logged = SESSION["logged_in"] or token in TOKENS
            return self.send_env({
                "logged_in": logged,
                "user_id": SESSION["user_id"] if logged else "",
                "name": SESSION["name"] if logged else "",
                "avatar": "",
            })
        if endpoint == "auth" and rest[:1] == ["logout"]:
            SESSION.update(logged_in=False, name="", user_id="")
            TOKENS.clear()
            return self.send_env({"logged_in": False})
        if endpoint in {"favorites", "history", "follows", "likes", "reservations"}:
            return self.send_env(page([]))
        if endpoint == "progress":
            if self.command == "POST":
                return self.send_env({"ok": True})
            return self.send_env({})
        if endpoint in {"like", "favorite", "subscribe", "follow"}:
            return self.send_env({"ok": True})

        return self.send_error_env(50100, f"endpoint not implemented: {endpoint}")

    def play(self) -> None:
        req = self.read_json()
        item_id = str(req.get("item_id", ""))
        episode = str(req.get("episode_id", ""))
        item = by_id(item_id)
        if not item or not episode:
            return self.send_error_env(40400, "item or episode not found")

        media = MEDIA_URL if MEDIA_URL else f"http://{self.headers.get('Host')}/media"
        token = seal(media)
        base = f"http://{self.headers.get('Host')}"
        url = f"{base}/v1/{SOURCE_ID}/asset/{urllib.parse.quote(token)}"

        plan = {
            "source": SOURCE_ID,
            "item_id": item_id,
            "episode_id": episode,
            "title": f"{item['title']} {episode}",
            "duration_ms": 8000,
            "streams": [{
                "id": "720p",
                "quality": "720p",
                "protocol": "http",
                "container": "mp4",
                "codec": "h264",
                "width": 720,
                "height": 1280,
                "mime_type": "video/mp4",
                "url": url,
            }],
            "downgraded": False,
            "expires_at": int(time.time()) + 3600,
        }
        return self.send_env(plan)

    # -- media -----------------------------------------------------------

    def serve_asset(self, token: str) -> None:
        try:
            target = unseal(token)
        except ValueError as exc:
            return self.send_error_env(40001, str(exc))

        range_header = self.headers.get("Range", "")
        start, end = 0, None
        if range_header:
            match = re.match(r"bytes=(\d+)-(\d*)", range_header)
            if not match:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */0")
                self.end_headers()
                return
            start = int(match.group(1))
            end = int(match.group(2)) if match.group(2) else None

        if target == f"http://{self.headers.get('Host')}/media":
            return self.serve_local(start, end)
        return self.proxy_remote(target, start, end)

    def serve_local(self, start: int, end: int | None) -> None:
        path = MEDIA_FILE
        if not os.path.isfile(path):
            return self.send_error_env(40400, f"media file not found: {path}")
        size = os.path.getsize(path)
        end = size - 1 if end is None else min(end, size - 1)
        if start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return
        length = end - start + 1
        ctype = mimetypes.guess_type(path)[0] or "video/mp4"
        status = 206 if self.headers.get("Range") else 200
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as fh:
            fh.seek(start)
            remaining = length
            while remaining > 0:
                chunk = fh.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def proxy_remote(self, url: str, start: int, end: int | None) -> None:
        headers = {}
        if self.headers.get("Range"):
            headers["Range"] = self.headers["Range"]
        req = urllib.request.Request(url, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=30) as upstream:
                status = upstream.status
                body = b"" if self.command == "HEAD" else upstream.read()
                ctype = upstream.headers.get("Content-Type", "video/mp4")
                total = upstream.headers.get("Content-Range", "")
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Accept-Ranges", "bytes")
                if status == 206 and total:
                    self.send_header("Content-Range", total)
                self.send_header("Content-Length", upstream.headers.get("Content-Length", str(len(body))))
                self.end_headers()
                if body:
                    self.wfile.write(body)
        except urllib.error.HTTPError as exc:
            return self.send_error_env(50010, f"upstream HTTP {exc.code}")
        except urllib.error.URLError as exc:
            return self.send_error_env(50010, f"upstream error: {exc.reason}")


def manifest() -> dict:
    return {
        "id": SOURCE_ID,
        "name": SOURCE_NAME,
        "version": "1.0.0",
        "protocol": "1",
        "description": "SourceProtocol v1 示例源",
        "icon": "",
        "capabilities": [
            "search", "detail", "episodes", "play", "feed",
            "rank", "new", "category", "ui_manifest",
        ],
        "brand": {"theme": {"seed": "#3B6CF6", "mode": "auto"}},
        "limits": {"max_page_size": 50, "search_timeout_ms": 5000},
        # 路径映射示例：客户端会用这些模板，而不是写死的 /v1/{sid}/ui。
        # 未列出的动作继续使用默认路径。
        "endpoints": {
            "ui": "/v1/demo/ui_test.php",
            "feed": "/v1/demo/feed_test.php",
        },
        "decryptors": [
            {"id": "builtin:cenc-ctr", "algorithms": ["cenc-ctr"], "abi": 1},
        ],
        # 自定义登录：字段名、类型、成功返回字段全部由源决定。
        "auth": {
            "required": False,
            "methods": ["form"],
            "credential_header": "Authorization",
            "credential_prefix": "Bearer ",
            "login": {
                "title": "示例登录",
                "description": "演示自定义登录；凭证只留在服务端。",
                "method": "form",
                "submit_label": "登录",
                "fields": [
                    {"key": "username", "label": "账号", "type": "text",
                     "required": True, "placeholder": "demo"},
                    {"key": "password", "label": "密码", "type": "password",
                     "required": True},
                ],
                "success_fields": ["user_id", "name", "avatar", "credentials"],
            },
        },
        "enabled": True,
    }


def main() -> None:
    listen = os.environ.get("FP_LISTEN", "127.0.0.1:8790")
    host, _, port = listen.rpartition(":")
    server = ThreadingHTTPServer((host or "127.0.0.1", int(port or "8790")), Handler)
    print(f"demo gateway on http://{listen} (source={SOURCE_ID})")
    print(f"media: {MEDIA_URL or MEDIA_FILE}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
