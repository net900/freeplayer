# SourceProtocol v1 源开发完整指南

> 目标读者：第一次为本播放器接入内容源的工程师，以及协助开发的 AI Agent。  
> 语言无关：**不要求 Go**。Python、PHP、Node、Java、Rust……只要实现本文的 HTTP 契约，就能成为一个源。  
> 数据约定：本文所有域名、ID、标题、频道、参数和响应都是**示例数据**，不对应任何真实上游。  
> 配套文件：
> - 可运行的 Python 网关示例：[`docs/source-dev/python_gateway_example.py`](source-dev/python_gateway_example.py)
> - 协议自检：[`docs/source-dev/protocol_check.py`](source-dev/protocol_check.py)
> - Agent 任务单模板：[`docs/source-dev/agent-task.example.json`](source-dev/agent-task.example.json)

---

## 目录

0. [10 分钟跑通最小源](#0-10-分钟跑通最小源)
1. [架构与边界](#1-架构与边界)
2. [两条接入路线](#2-两条接入路线)
3. [协议基础](#3-协议基础)
4. [核心数据结构](#4-核心数据结构)
5. [端点清单与实现优先级](#5-端点清单与实现优先级)
6. [UI Manifest：菜单即数据](#6-ui-manifest菜单即数据)
7. [客户端实际消费的字段](#7-客户端实际消费的字段)
8. [播放与媒体管线](#8-播放与媒体管线)
9. [认证与账号](#9-认证与账号)
10. [测试与验收](#10-测试与验收)
11. [红线与常见错误](#11-红线与常见错误)
12. [AI Agent 开发协议](#12-ai-agent-开发协议)
13. [附录：示例响应与字段表](#13-附录示例响应与字段表)

---

## 0. 10 分钟跑通最小源

### 0.1 准备

- 一个竖屏或横屏 MP4（示例路径：`docs/source-dev/sample.mp4`）
- Python 3.9+（示例只用标准库）

### 0.2 启动示例网关

```bash
python docs/source-dev/python_gateway_example.py
```

默认监听 `http://127.0.0.1:8790`，源 ID 为 `demo`。若要指定视频：

```bash
FP_MEDIA_FILE=/path/to/sample.mp4 FP_LISTEN=127.0.0.1:8790 \
  python docs/source-dev/python_gateway_example.py
```

### 0.3 在客户端里连接

1. 打开客户端首启页 /「添加云端地址」。
2. 填 `http://127.0.0.1:8790`（也可以直接填源列表的任意路径，例如
   `http://127.0.0.1:8790/v1/sources_test.php`）。
3. 选择「示例源」进入。

此时应能看到：首页信息流、搜索、榜单、新上、分类、详情、选集、播放。

### 0.4 用命令行自检

```bash
curl -s http://127.0.0.1:8790/v1/sources
curl -s -H 'X-Client-Pages: home.feed,search,list.rank' \
  http://127.0.0.1:8790/v1/demo/ui
curl -s 'http://127.0.0.1:8790/v1/demo/feed?limit=2'
curl -s 'http://127.0.0.1:8790/v1/demo/detail/demo-1'
curl -s 'http://127.0.0.1:8790/v1/demo/episodes/demo-1'
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"item_id":"demo-1","episode_id":"demo-1-ep1","quality":"auto"}' \
  http://127.0.0.1:8790/v1/demo/play
```

拿到 `streams[0].url` 后：

```bash
curl -s -D - -o /dev/null -H 'Range: bytes=0-255' '<asset-url>'
```

期望 `HTTP 206`、`Content-Range: bytes 0-255/<total>`，且前 12 字节包含 `ftyp`。

一键自检：

```bash
python docs/source-dev/protocol_check.py --base http://127.0.0.1:8790
```

---

## 1. 架构与边界

```text
┌────────────────────┐      SourceProtocol v1       ┌────────────────────┐
│  Flutter 客户端     │  ──────────────────────────▶ │  网关 / 源服务      │
│  只渲染协议数据      │ ◀──────────────────────────  │  业务与上游适配      │
└────────────────────┘                               └────────────────────┘
                                                              │
                                                              ▼
                                                      ┌────────────────────┐
                                                      │  真实上游 / 数据库   │
                                                      └────────────────────┘
```

三条硬边界：

1. **客户端不含源知识。** 菜单、页面标题、品牌、指标名、登录文案都应来自源的 manifest / UI manifest。
2. **上游直链和源内部密钥不落到客户端。** 设备档案、签名密钥、内容密钥、上游直链只存在于源侧；
   登录 token/cookie 只能经登录响应的 `credentials` 显式返回。
3. **页面类型是封闭集合。** 源只能从既定类型里选，不能发明新页面。

依赖方向（任何语言都适用）：

```text
路由/HTTP 层  →  协议 DTO 层
路由/HTTP 层  →  上游适配层  →  上游
协议 DTO 层   ✗→  上游/业务
```

协议层只认识 JSON 形状，不认识任何具体上游。

---

## 2. 接入方式

### 2.1 独立源服务（推荐）

任何语言实现一个 HTTP 服务，直接对客户端提供「源列表」和其余动作。
客户端把地址当成「云端地址」，不需要知道服务是用什么写的。

- 入口可以是任意 URL：`http://host/v1/sources`、`http://host/v1/xxx/sources_test.php`、
  `https://host/api/list` 都可以（见 3.5）。
- 其余动作的路径由 manifest 的 `endpoints` 决定，不要求使用默认后缀。
- 优点：语言自由；部署独立；可以单独扩缩容。
- 代价：媒体代理、Range、解密、缓存需要你自己实现（明文 MP4 的 Range 代理很简单）。
- 参考实现：[`python_gateway_example.py`](source-dev/python_gateway_example.py)。

### 2.2 嵌入本地核心（可选）

如果希望源和客户端一起分发，可以把源实现为本地核心的一部分：核心在 `127.0.0.1`
的随机端口上运行同一个 HTTP 契约，客户端把它当成普通源服务。
这不会改变本文的任何协议字段；具体语言、进程模型和打包方式由你决定。

### 2.3 本地核心的端口与冲突

**不要假设固定端口。** 本地核心应绑定 `127.0.0.1:0`，让操作系统分配一个空闲端口；
核心把实际端口通过桥接接口（例如 `FPCorePort`）告诉客户端，客户端再用
`http://127.0.0.1:<实际端口>` 访问。

这样即使 `8787` 或任何习惯端口被其他程序占用，核心仍能启动，不需要端口扫描或人工改配置。
客户端的地址输入框也只认最终 URL，不认某个固定端口。

独立源服务同理：监听哪个端口由你决定；客户端填的是源列表 URL，所以端口可以任意。

如果你必须保留固定端口的习惯，按这个顺序处理：

1. 先尝试首选端口（例如 `8787`）；
2. 捕获 `address already in use` / `EADDRINUSE`；
3. 改为绑定端口 `0`（系统分配）或尝试下一个端口；
4. 把**最终端口**通过桥接接口、日志或启动输出告诉客户端；
5. 客户端只用最终 URL，不假设首选端口。

不要用「端口被占用就直接退出」作为唯一行为；至少要让调用方拿到可用的实际端口。

两种方式共用同一份协议契约。本文第 3–10 节对两者都适用。

### 2.4 以 DLL 分发源（可选）

也可以把整个源做成一个 Windows DLL，由客户端下载后在进程内加载。用户不需要填地址，源也不会以独立进程出现。

必须导出的 C 接口（Windows x64，任意能产出 DLL 的语言）：

| 导出 | 说明 |
|---|---|
| `FPCoreStart(const char* dataDir, const char* toolsDir)` | 启动核心。两个目录都由客户端创建并传入；核心只往 `dataDir` 写数据（设备档案、登录态、缓存）。应立即返回，后台完成启动。 |
| `FPCorePort()` | 返回实际监听端口：`> 0` 表示可用，`0` 表示尚未就绪，`< 0` 表示启动失败。 |
| `FPCoreError()` | 失败原因（UTF-8 字符串），只在 `FPCorePort() < 0` 时读取。 |
| `FPCoreStop()` | 停止服务；客户端退出时调用。 |

规则：

- 必须绑定 `127.0.0.1:0`，实际端口通过 `FPCorePort()` 告知客户端，不要假设固定端口（见 2.3）。
- 对外契约与 2.1 完全相同：客户端把它当成普通的「源服务」访问。
- 同一个 DLL 可以再导出 `fp_cenc_*`（见 8.7），这样「源 + 解密器」只需一个文件、一次下载；客户端会优先使用 `cenc_decrypt.dll`，没有时回退到核心 DLL。
- 不要把 DLL 打进安装包。客户端启动时按清单下载并显示进度（已下载 / 总大小、百分比），校验大小和 SHA-256 后安装到 `decryptors\`，失败则保留旧版本继续使用。

清单接口只需要四个字段（外层包不包 `{code,message,data}` 都可以）：

```json
{
  "version": "1.0.0",
  "url": "https://source.example.test/files/core.dll",
  "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "size": 9888256
}
```

`sha256`、`size` **必须**按文件实时计算；客户端只在两者都匹配时安装。换版本时替换文件即可，客户端下次启动发现哈希变化就会重新下载。



---

## 3. 协议基础

### 3.1 统一信封

所有 JSON 响应（包括错误）都是：

```json
{
  "code": 0,
  "message": "ok",
  "data": {},
  "trace_id": "c4d42cce1a477931"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `code` | int | `0` 成功；非 0 为错误码 |
| `message` | string | 人类可读信息 |
| `data` | any | 成功时的数据；错误时可省略或为 `null` |
| `trace_id` | string | 排障用；建议每次请求生成新的 |

**HTTP 状态码约定**：

- 协议错误也返回 **HTTP 200**，错误体现在 `code`。
- 只有上游超时返回 **HTTP 504**（客户端仍按信封解析）。
- 不要用 4xx/5xx 表达业务错误，否则客户端可能把它当成网络故障。

### 3.2 请求头

客户端每个请求都会带：

| 头 | 说明 |
|---|---|
| `X-Client-Id` | 客户端标识；服务端可校验，也可忽略 |
| `X-Source-Protocol` | 固定 `1` |
| `X-Client-Pages` | 仅 `/ui` 请求带；逗号分隔的页面类型白名单 |

`X-Client-Pages` 示例：

```text
home.feed,search,list.rank,list.new,list.category,detail,library.history,library.follow,library.reservations,library.likes,library.favorites,library.downloads,player
```

源在生成 UI manifest 时应**丢弃**不在白名单里的页面；白名单为空时返回全部。

### 3.3 错误码

| code | 含义 | 典型场景 |
|---|---|---|
| `0` | 成功 | — |
| `40001` | 参数错误 | 缺少 `item_id`、`episode_id`、非法 JSON |
| `40100` | 未登录 | 关注列表、需要账号的接口 |
| `40300` | 无权限 | 账号被限制 |
| `40400` | 不存在 | 条目/选集不存在、未知源 |
| `42900` | 限流 | 上游限流 |
| `50010` | 上游失败 | 网络错误、上游 5xx、解析失败 |
| `50100` | 不支持 | 可选能力未实现 |

客户端对 `50100` 的处理是「该页/该功能不可用」，通常不会白屏；对 `40100` 会引导登录。
其余错误显示重试态。

### 3.4 分页

分页字段有两套别名，**源应同时返回**，以兼容不同客户端：

```json
{
  "items": [],
  "next": "20",
  "next_cursor": "20",
  "has_more": true,
  "total": 20
}
```

规则：

- `cursor` 对客户端是**不透明字符串**；内部可以是 offset、游标、token，但必须稳定。
- 没有下一页时 `next` / `next_cursor` 返回空字符串，`has_more` 为 `false`。
- 同一个 `cursor` 重复请求应返回同一页（允许上游内容变化，但不要无限循环）。
- `limit` 默认 20，建议上限 50；源可以 clamp。

### 3.5 路径映射（不限制 URL）

协议只规定**数据形状**，不规定路径。所有路径都可以由源自己决定，客户端通过 manifest 的
`endpoints` 映射调用。

#### 3.5.1 源列表入口

用户在客户端里填的地址就是源列表入口：

- 地址没有路径（如 `http://127.0.0.1:8790`）→ 客户端请求 `/v1/sources`。
- 地址带路径（如 `http://127.0.0.1:8790/v1/xxx/sources_test.php`）→ 客户端**原样请求这个地址**。

所以入口可以是 `sources.php`、`sources_test.php`、`/api/list`，只要返回
`{"sources":[...]}` 信封即可。

#### 3.5.2 其余动作的 `endpoints` 映射

每个源在 manifest 里声明逻辑动作到路径模板的映射：

```json
{
  "id": "demo",
  "endpoints": {
    "ui": "/v1/xxx/ui_test.php",
    "tabs": "/v1/xxx/tabs.php",
    "feed": "/v1/xxx/feed.php",
    "search": "/v1/xxx/search.php",
    "detail": "/v1/xxx/item.php?item_id={item_id}",
    "episodes": "/v1/xxx/episodes.php?item_id={item_id}",
    "play": "/v1/xxx/play.php",
    "comments_reply": "/v1/xxx/reply.php?id={comment_id}",
    "comments_delete": "/v1/xxx/abc.php?comment_id={comment_id}"
  }
}
```

规则：

- 模板可以是**绝对路径**（`/v1/...`）、**相对路径**，或**绝对 URL**（`https://...`）。
- 可用占位符：`{source_id}`、`{item_id}`、`{comment_id}`、`{album_id}`。
- 没有列出的动作使用客户端默认路径；因此旧源不需要改。
- 如果模板是绝对 URL，客户端不会拼接网关地址。
- 查询参数可以写在模板里；客户端会追加自己的 query（同名参数以模板为准）。

#### 3.5.3 逻辑动作键

| 键 | 默认路径 |
|---|---|
| `ui` | `/v1/{source_id}/ui` |
| `tabs` | `/v1/{source_id}/tabs` |
| `feed` | `/v1/{source_id}/feed` |
| `prefetch` | `/v1/{source_id}/prefetch` |
| `search` | `/v1/{source_id}/search` |
| `detail` | `/v1/{source_id}/detail/{item_id}` |
| `episodes` | `/v1/{source_id}/episodes/{item_id}` |
| `play` | `/v1/{source_id}/play` |
| `rank` | `/v1/{source_id}/rank` |
| `rank_meta` | `/v1/{source_id}/rank/meta` |
| `new` | `/v1/{source_id}/new` |
| `calendar` | `/v1/{source_id}/calendar` |
| `category` | `/v1/{source_id}/category` |
| `category_meta` | `/v1/{source_id}/category/meta` |
| `suggest` | `/v1/{source_id}/suggest` |
| `stats` | `/v1/{source_id}/stats` |
| `danmaku` | `/v1/{source_id}/danmaku` |
| `comments` | `/v1/{source_id}/comments` |
| `comments_reply` | `/v1/{source_id}/comments/{comment_id}/reply` |
| `comments_like` | `/v1/{source_id}/comments/{comment_id}/like` |
| `comments_delete` | `/v1/{source_id}/comments/{comment_id}/delete` |
| `emoticons` | `/v1/{source_id}/emoticons` |
| `reservations_delete` | `/v1/{source_id}/reservations/delete` |
| `like` | `/v1/{source_id}/like` |
| `favorite` | `/v1/{source_id}/favorite` |
| `follow` | `/v1/{source_id}/follow` |
| `subscribe` | `/v1/{source_id}/subscribe` |
| `auth_login` | `/v1/{source_id}/auth/login` |
| `auth_qrcode` | `/v1/{source_id}/auth/qrcode` |
| `auth_qrcode_status` | `/v1/{source_id}/auth/qrcode/status` |
| `auth_sms_send` | `/v1/{source_id}/auth/sms/send` |
| `auth_sms_login` | `/v1/{source_id}/auth/sms/login` |
| `auth_me` | `/v1/{source_id}/auth/me` |
| `auth_logout` | `/v1/{source_id}/auth/logout` |
| `favorites` / `history` / `follows` / `likes` / `reservations` | `/v1/{source_id}/...` |
| `album` | `/v1/{source_id}/album/{item_id}` |
| `plan` | `/v1/{source_id}/plan` |
| `progress` | `/v1/{source_id}/progress` |
| `share` | `/v1/{source_id}/share` |
| `endpoints` | `/v1/{source_id}/endpoints` |

> `/asset` 不需要映射：播放响应里的 `streams[].url` 就是完整 URL，客户端直接使用。

---

## 4. 核心数据结构

### 4.1 源清单 `SourceManifest`

`GET /v1/sources` 返回：

```json
{
  "sources": [
    {
      "id": "demo",
      "name": "示例源",
      "version": "1.0.0",
      "protocol": "1",
      "description": "用于文档演示的示例源",
      "icon": "",
      "capabilities": ["search", "detail", "episodes", "play", "feed", "ui_manifest"],
      "brand": { "theme": { "seed": "#3B6CF6", "mode": "auto" } },
      "limits": { "max_page_size": 50, "search_timeout_ms": 5000 },
      "auth": { "required": false, "methods": [] },
      "endpoints": {
        "ui": "/v1/xxx/ui_test.php",
        "feed": "/v1/xxx/feed.php"
      },
      "decryptors": [
        { "id": "builtin:cenc-ctr", "algorithms": ["cenc-ctr"], "abi": 1 }
      ],
      "enabled": true
    }
  ]
}
```

规则：

- `id` 一旦发布不要改；它出现在所有 URL 和 `source` 字段里。
- `protocol` 必须是 `"1"`。
- `capabilities` 会影响客户端兜底菜单：
  - `feed` → 显示首页入口
  - `rank` → 显示榜单
  - `new` → 显示新上
  - `category` → 显示分类
  - `auth` → 显示账号入口
  - 其他值（`search`、`ui_manifest` 等）为声明性信息，不影响兜底菜单。
- **优先提供 `/ui`**；只有 `/ui` 不可用时客户端才用 `capabilities` 生成兜底菜单。
- `endpoints` 可把任意逻辑动作映射到任意路径或绝对 URL（见 3.5）；不写则用默认路径。
- `decryptors` 声明内置或可下载的解密器；可下载项必须带 `sha256`（见 8.7）。
  没有解密需求时省略。

### 4.2 条目 `Item`

```json
{
  "source": "demo",
  "id": "demo-1",
  "item_id": "demo-1",
  "type": "series",
  "title": "示例剧集：第一季",
  "cover": "",
  "description": "用于演示详情、选集与播放链路。",
  "episode_count": 3,
  "tags": ["示例", "剧情"],
  "badges": ["示例"],
  "updated_at": "2026-10-31",
  "extra": {
    "vid": "demo-1-ep1",
    "first_vid": "demo-1-ep1",
    "episode_count": 3,
    "heat": 12000,
    "follow_count": 3400,
    "play_count": 56000
  }
}
```

必须：

- `id` 和 `item_id` **都写**（客户端 DTO 读 `id`，协议读 `item_id`）。
- `source` 写源 ID。
- `title` 非空。

建议：

- `type` 用 `series` / `movie` / `video` 等稳定值。
- `cover` 是客户端可直接加载的图片 URL（见 8.5）。
- `episode_count` 写总集数；列表行不要求准确，详情页应准确。
- `extra` 是开放字段，但客户端会读取其中一些约定键（见第 7 节）。

### 4.3 选集 `Episode`

```json
{
  "episode_id": "demo-1-ep1",
  "id": "demo-1-ep1",
  "index": 1,
  "title": "第 1 集",
  "duration_sec": 8,
  "duration_ms": 8000,
  "cover": "",
  "extra": {}
}
```

`GET /episodes/{item_id}` 返回：

```json
{
  "item_id": "demo-1",
  "items": [ ... ],
  "episodes": [ ... ],
  "next": "",
  "next_cursor": "",
  "has_more": false
}
```

`items` 与 `episodes` 是同一份数据的两个别名，**都要写**。

### 4.4 播放计划 `MediaPlan`

```json
{
  "source": "demo",
  "item_id": "demo-1",
  "episode_id": "demo-1-ep1",
  "title": "示例剧集：第一季 第 1 集",
  "duration_ms": 8000,
  "streams": [
    {
      "id": "720p",
      "quality": "720p",
      "protocol": "http",
      "container": "mp4",
      "codec": "h264",
      "width": 720,
      "height": 1280,
      "bandwidth": 1200000,
      "mime_type": "video/mp4",
      "url": "http://127.0.0.1:8790/v1/demo/asset/<opaque-token>"
    }
  ],
  "subtitles": [],
  "next_episode_id": "demo-1-ep2",
  "prev_episode_id": "",
  "downgraded": false,
  "expires_at": 1793391642
}
```

关键点：

- `streams` 至少一条。
- `url` 必须能被客户端直接播放，且支持 Range（见第 8 节）。
- `quality` 建议用 `360p/540p/720p/1080p` 或 `auto`；客户端把第一条当默认。
- `expires_at` 是 Unix 秒；过期后客户端会重新调用 `/play`。
- 若要支持多档切换，把所有档位都放进 `streams`，第一条为默认。
- 需要客户端本地解密时，在 `MediaPlan` 或单个 `stream` 上附带 `decryption`
  （`location:"client"` + `key_hex`，见 8.3 与 8.7）。不需要时省略。

---

## 5. 端点清单与实现优先级

### 5.1 必做（最小源）

| 方法 | 路径 | 说明 | 客户端行为 |
|---|---|---|---|
| GET | `/v1/sources` | 源列表 | 连接地址后展示可选源 |
| GET | `/v1/{sid}/ui` | UI manifest | 渲染菜单；缺失则兜底 |
| GET | `/v1/{sid}/search?q=&cursor=&limit=` | 搜索 | 搜索页 |
| GET | `/v1/{sid}/detail/{item_id}` | 条目详情 | 详情页 |
| GET | `/v1/{sid}/episodes/{item_id}` | 选集 | 详情页选集 |
| POST | `/v1/{sid}/play` | 播放计划 | 播放器 |
| GET | `/v1/{sid}/asset/{token}` | 媒体流 | 播放器请求（支持 Range） |

> `/play` 是 POST，body 为 `{"item_id","episode_id","quality","prefer","decrypt_location","prewarm"}`。
> `quality` 可能是 `auto` 或 `720p`；未知值按默认处理。

### 5.2 强烈建议（完整体验）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v1/{sid}/tabs` | 首页顶部标签：`{"tabs":[{"key","title","channel"}]}` |
| GET | `/v1/{sid}/feed?channel=&cursor=&limit=` | 首页信息流 |
| GET | `/v1/{sid}/rank?type=&sub=&time=&panel=&cursor=&limit=` | 榜单 |
| GET | `/v1/{sid}/rank/meta?type=&sub=` | 榜单筛选项 |
| GET | `/v1/{sid}/new?gender=2&cursor=&limit=` | 新上（2 全部 / 1 男频 / 0 女频） |
| GET | `/v1/{sid}/category?genre=&theme=&role=&epoch=&sort=&gender=&online_time=&cursor=&limit=` | 分类 |
| GET | `/v1/{sid}/category/meta` | 分类筛选项 |
| GET | `/v1/{sid}/suggest?q=&limit=` | 搜索联想：`{"words":[],"items":[]}` |
| GET | `/v1/{sid}/stats?ids=a,b&vid=` | 卡片指标：`{"stats":{"<id>":{...}}}` |
| GET | `/v1/{sid}/comments?item_id=&episode_id=&kind=&cursor=&limit=` | 评论/剧评/弹幕列表 |
| GET | `/v1/{sid}/danmaku?item_id=&episode_id=&duration=&offset=` | 弹幕 |
| GET | `/v1/{sid}/album/{item_id}?album_id=` | 合集/系列 |
| GET | `/v1/{sid}/plan?item_id=&scene=&from=&cursor=&limit=` | 相关推荐/其它季 |
| GET | `/v1/{sid}/emoticons` | 表情包 |
| POST | `/v1/{sid}/auth/login` | 自定义登录 `{method,fields}`（见 9.2） |
| GET | `/v1/{sid}/auth/qrcode` | 扫码登录二维码 |
| GET | `/v1/{sid}/auth/qrcode/status?token=` | 扫码状态 |
| GET | `/v1/{sid}/auth/me` | 当前账号 |
| POST | `/v1/{sid}/auth/logout` | 退出 |
| POST | `/v1/{sid}/like` | `{item_id, liked}` |
| POST | `/v1/{sid}/favorite` | `{item_id, favorite}` |
| POST | `/v1/{sid}/subscribe` | `{item_id, reserve}` |
| POST | `/v1/{sid}/follow` | `{item_id, follow}` |
| GET | `/v1/{sid}/favorites` / `history` / `follows` / `likes` / `reservations` | 账号片库 |
| GET/POST | `/v1/{sid}/progress` | 读取/上报进度 |
| POST | `/v1/{sid}/comments` | 发评论/弹幕 |
| POST | `/v1/{sid}/comments/{id}/reply` | 回复 |
| POST | `/v1/{sid}/comments/{id}/like` | 评论点赞 |
| POST | `/v1/{sid}/comments/{id}/delete` | 删除自己的内容 |

未实现的可选端点返回 `50100`，客户端会降级，不会崩溃。

### 5.3 静态筛选面板

`/rank/meta` 与 `/category/meta` 的形状（客户端按此渲染筛选 chips）：

```json
{
  "groups": [
    {
      "key": "audience",
      "title": "受众",
      "multi": false,
      "depends_on": "",
      "options": [
        { "id": "all", "label": "全部", "parent": "" },
        { "id": "group_a", "label": "示例分组", "parent": "" }
      ]
    }
  ],
  "defaults": { "audience": "all" }
}
```

`/category/meta` 直接返回 `{"groups":[...]}`；`/rank/meta` 额外带 `defaults`。

### 5.4 首页标签

```json
{
  "tabs": [
    { "key": "home", "title": "精选", "channel": "home" },
    { "key": "series", "title": "连载", "channel": "series" }
  ]
}
```

`channel` 会原样传给 `/feed`。**不要在客户端里预置任何频道值**；标签完全由源决定。

---

## 6. UI Manifest：菜单即数据

`GET /v1/{sid}/ui` 的响应：

```json
{
  "ui_version": 1,
  "default_page": "home.feed",
  "theme": { "seed": "#3B6CF6", "mode": "auto" },
  "home_tabs": [
    { "key": "home", "title": "精选", "channel": "home" },
    { "key": "series", "title": "连载", "channel": "series", "category_tag": "示例分类" },
    { "key": "mine", "title": "我的追更", "channel": "following", "requires_auth": true }
  ],
  "navigation": [
    {
      "title": "内容",
      "icon": "home",
      "items": [
        { "title": "首页", "icon": "home", "page": "home.feed" },
        { "title": "搜索", "icon": "search", "page": "search" },
        { "title": "榜单", "icon": "leaderboard", "page": "list.rank" },
        { "title": "新上", "icon": "fiber_new", "page": "list.new" },
        { "title": "分类", "icon": "category", "page": "list.category" }
      ]
    },
    {
      "title": "片库",
      "icon": "video_library",
      "items": [
        { "title": "历史", "icon": "history", "page": "library.history" },
        { "title": "收藏", "icon": "favorite", "page": "library.favorites" },
        { "title": "下载", "icon": "download", "page": "library.downloads" }
      ]
    }
  ],
  "labels": {
    "play": "播放",
    "play_full": "观看完整剧集 · 全{count}集"
  }
}
```

### 6.0 首页标签 `home_tabs`

`home_tabs` 与 UI manifest 一起返回，客户端打开首页时**不需要再请求 `/tabs`**，也不会有任何内置默认标签。

| 字段 | 说明 |
|---|---|
| `key` | 稳定标识，用于本地偏好与日志 |
| `title` | 显示文案 |
| `channel` | 原样传给 `/feed` |
| `requires_auth` | `true` 时未登录显示登录引导；客户端不再靠频道名判断 |
| `category_tag` | 该标签内容不足时，用这个分类继续补足；空表示不补 |

> 旧网关没有 `home_tabs` 时，客户端才回退到 `/tabs`。新源应始终提供 `home_tabs`。

### 6.1 允许的页面类型（封闭集合）

| page | 用途 | 客户端读取的 params |
|---|---|---|
| `home.feed` | 全屏信息流 | 无（标签来自 `/tabs`） |
| `search` | 搜索 | `q`（初始关键词） |
| `list.rank` | 榜单 | 无（筛选来自 `/rank/meta`） |
| `list.new` | 新上 | 无 |
| `list.category` | 分类 | `tags`（逗号分隔的标签） |
| `detail` | 详情 | 由壳路由，不在菜单里 |
| `library.history` | 历史 | 无 |
| `library.follow` | 追更/预约 | 无 |
| `library.reservations` | 预约 | 无 |
| `library.likes` | 点赞 | 无 |
| `library.favorites` | 收藏 | 无 |
| `library.downloads` | 下载 | 无 |
| `player` | 播放器 | 由壳路由，不在菜单里 |

不在表中的 `page` 会被客户端**隐藏并记日志**，不会崩溃。不要发明新的页面类型。

### 6.2 图标

客户端内置以下名称，未知名称显示中性圆点：

`home`、`search`、`leaderboard`/`rank`、`fiber_new`/`new`、`category`、`video_library`/`library`、`history`、`favorite`、`download`、`playlist`/`playlist_play`、`settings`、`login`、`account`。

### 6.3 文案 labels

`labels` 是源提供的字符串表。客户端不内置任何产品文案；缺失的键使用中性兜底。
以下键当前会被读取：

| 键 | 用途 | 占位符 |
|---|---|---|
| `play` | 播放入口兜底 | — |
| `play_full` | 首页「看全剧」按钮 | `{count}` |
| `home.login_required_title` | 需要登录的标签页标题 | — |
| `home.login_required_body` | 需要登录的标签页说明 | — |
| `home.login_action` | 登录按钮 | — |
| `detail.hot_label` | 详情页热度指标名 | — |
| `detail.follows_label` | 详情页追剧指标名 | — |
| `detail.plays_label` | 详情页播放指标名 | — |
| `detail.tab.episodes` | 详情页「选集」 | — |
| `detail.tab.series` | 详情页「系列」 | — |
| `detail.tab.reviews` | 详情页「剧评」 | — |
| `detail.tab.related` | 详情页「相关」 | — |
| `new.tab.recommend` | 新上页第 1 个标签 | — |
| `new.tab.calendar` | 新上页第 2 个标签 | — |
| `new.gender.all` / `male` / `female` | 受众筛选 | — |
| `new.empty_day` | 日历当天为空 | — |
| `search.type_fallback` | 联想项无副标题时的词 | — |
| `login.title` | 登录弹层标题 | — |
| `login.qr_tab` / `login.sms_tab` | 登录方式切换 | — |
| `login.message` | 等待登录提示 | — |
| `login.message_limited` | 触发限流时的提示 | — |
| `login.scanned` / `confirmed` / `expired` / `waiting` | 扫码状态 | — |
| `login.code_sent` | 验证码已发送 | — |
| `login.refresh_qr` | 刷新二维码按钮 | — |
| `login.phone` / `login.code` | 输入框标签 | — |
| `login.send_code` / `login.sending` / `login.action` | 短信表单按钮 | — |
| `login.sms_hint` | 短信方式提示 | — |
| `login.error_limited` | 限流说明 | — |
| `login.steps` | 登录步骤，`\n` 分隔 | — |
| `login.required` | 自定义登录必填提示 | `{field}` |

`labels` 是开放表；源可以提供额外键，客户端会忽略不认识的键。文案应保持中性，不要写死产品名或外部 App 名。

### 6.4 主题

`theme.seed` 是十六进制颜色；`mode` 为 `auto/light/dark`。客户端用它生成主题色。
`brand` 在 UI manifest 中可写，但当前客户端只读取 `theme`。

### 6.5 兜底菜单

如果 `/ui` 返回 `50100` 或 manifest 里没有任何可用页面，客户端会按 `capabilities` 生成兜底菜单：

- `feed` → 首页
- 搜索始终存在
- `rank` / `new` / `category` → 对应列表
- 片库页面始终存在（历史/收藏/追更/预约/点赞/下载）

兜底文案是框架通用文案，不是产品文案。

---

## 7. 客户端实际消费的字段

这一节是从客户端代码反推的**兼容契约**。源不必全部提供，但提供得越完整，页面越完整。

### 7.1 `stats` 字段

`GET /v1/{sid}/stats` 返回：

```json
{
  "stats": {
    "demo-1": {
      "episode_cnt": 3,
      "episode_index": 1,
      "play_count": 56000,
      "like_count": 100,
      "comment_count": 8,
      "follow_count": 3400,
      "favorite_count": 20,
      "season_index": 1,
      "multi_season": false,
      "status": 0,
      "duration_sec": 8,
      "categories": ["示例", "剧情"],
      "liked": false
    }
  }
}
```

客户端读取的键：`episode_cnt`、`episode_index`、`play_count`、`like_count`、
`comment_count`、`follow_count`、`favorite_count`、`season_index`、`multi_season`、
`status`、`duration_sec`、`categories`、`liked`。

`status` 约定：`0` 连载中，`1` 已完结（客户端据此显示状态）。

### 7.2 `item.extra` 兼容键

| 键 | 用途 |
|---|---|
| `vid` | 首页卡片/评论/统计定位「当前视频/剧集」 |
| `first_vid` | 详情页首集点赞状态 |
| `is_series` | 首页浮层显示「系列剧」 |
| `episode_count` / `episode_cnt` / `vid_index` | 集数、进度 |
| `heat` / `hot_score` / `score` / `score_count` | 热度、评分 |
| `play_count` / `follow_count` / `like_count` / `comment_count` | 指标 |
| `liked` / `followed` / `first_liked` | 交互状态 |
| `is_online` / `status` / `finished` / `up_to_date` / `publish_at` | 上线/更新状态 |
| `categories` / `category` | 分类标签 |
| `reserve_id` / `current` / `position_sec` | 预约、续播 |

建议：

- 只写与页面有关的键；缺失时客户端会降级。
- 源私有字段请加前缀（如 `vendor_*`），避免与未来协议字段冲突。
- 大整数 ID 用字符串，避免 JSON `float64` 精度丢失。

### 7.3 评论/弹幕形状

`/comments` 返回：

```json
{
  "items": [
    {
      "id": "c1",
      "text": "示例评论",
      "user_name": "示例用户",
      "avatar": "",
      "like_count": 3,
      "liked": false,
      "created_at": "2026-10-31 12:00"
    }
  ],
  "next": "",
  "total": 1
}
```

`/danmaku` 返回：

```json
{
  "items": [
    { "id": "d1", "text": "示例弹幕", "offset_sec": 1.2, "color": "#FFFFFF" }
  ],
  "generated": true
}
```

`generated: true` 表示这是源本地生成的示例弹幕（没有真实上游弹幕时可用）。

---

## 8. 播放与媒体管线

### 8.1 三种媒体模式

| 模式 | 源要做什么 | 谁解密 |
|---|---|---|
| 明文直链 | 返回可访问的 `url` | 不需要 |
| 源侧解密 | 源自己解密后输出明文 | 源 |
| 本地核心解密 | 返回密文 URL + `decryption` 描述 | 客户端本地核心 |

对客户端而言三种模式没有区别：它只看到一个支持 Range 的 `video/mp4` URL。

### 8.2 明文 Range 代理（任意语言）

最小要求：

1. `/play` 返回一个**你自己的** `asset` URL（不要直接把上游 URL 给客户端）。
2. `asset` 端点支持：
   - `Accept-Ranges: bytes`
   - `Range: bytes=start-end` → `206 Partial Content`
   - `Content-Range: bytes start-end/total`
   - 正确的 `Content-Length` 与 `Content-Type`
3. 无 Range 时返回 `200` 与完整内容。
4. `HEAD` 请求只返回头，不返回 body。

示例实现见 `python_gateway_example.py` 的 `serve_local` / `proxy_remote`。

> 如果上游不支持 Range，你的代理需要在本地切片；不要向上游整文件下载后再回 206
> 之外还假装支持 Range，否则播放器拖动会失败。

### 8.3 加密媒体：解密在本地

CENC 解密发生在**客户端本地的核心/解密器**，不走远端后端。源有两种做法：

1. **自己解密（推荐给独立网关）**：在你的服务里解密，`asset` 输出明文 MP4 + Range。
   客户端只会看到明文；密钥、上游 URL、cookie 都不离开你的服务。
2. **交给本地核心**：`/play` 返回密文 URL，并附带 `decryption` 描述；
   本地核心按描述解密后再交给播放器。适用于源和本地核心一起分发的情况。

`decryption` 可以放在 `MediaPlan` 上（整集默认），也可以放在 `streams[]` 上（按档位覆盖）：

```json
{
  "required": true,
  "location": "client",
  "algorithm": "cenc-ctr",
  "handler": "",
  "key_hex": "00112233445566778899aabbccddeeff",
  "iv_size": 8,
  "params": {}
}
```

客户端在 `location == "client"` 且 `key_hex` 非空时，会在本机启动一个 loopback
代理：播放器向它请求 Range，它从源拉取密文区间，用本地解密器 DLL 解密后返回明文。
源和远端服务都不参与解密。

规则：

- 密钥只走「源 → 客户端本地」链路；**不要写日志、不要放进 URL query、不要放进公开的 `extra`**。
- 独立网关如果不想把密钥交给客户端，请自己解密并输出明文（8.2）。
- 解密能力以客户端版本和本地 DLL 为准；缺失时返回 `40410`（decryptor missing），
  或由你的服务转成明文。
- 不论哪种方式，播放器最终拿到的都必须是支持 Range 的 `video/mp4`。
- 每个样本必须完整解密（AES-CTR 不能从样本中间开始），所以 Range 会被扩展到样本边界。

### 8.4 画质选择

- `quality: auto`：源自行决定默认档；建议按**短边**（`min(width,height)`）排序，不要把竖屏的 `720×1280` 误判为低于横屏 `1280×720`。
- `quality: 720p` / `1080p`：尽量返回该档；没有则返回最接近的档并置 `downgraded: true`。
- `prefer.max_height` / `prefer.codec` / `prefer.max_bitrate` 可作为额外约束。
- 所有档位都放进 `streams`，客户端可即时切换。

### 8.5 封面与进度预览

- `Item.Cover`、`Episode.Cover` 由客户端直接加载。**没有通用封面代理**：
  - 必须是客户端可访问的 URL；
  - 若上游封面需要签名/防盗链，请在自己的服务里转成公开 URL，或返回空字符串让客户端显示渐变占位。
- 播放进度预览由**客户端本地生成**：对每个视频，客户端用随应用分发的 ffmpeg
  按时间点抽帧、拼成雪碧图并缓存，再显示在进度条悬停处。
  - 源**只需要给出一个能播放的 MP4**：雪碧图、切片参数、转码接口都不需要；
  - 抽帧是对视频的少量 Range 读取，不会把整集下载一遍；
  - 缓存按视频地址（host+path）复用，源换签名参数不会导致重复生成；
  - 客户端缺 ffmpeg 或视频不可读时，进度条退化为普通滑条。
- 如果源另外提供了现成的预览图地址（可选优化），客户端会在剧集列表加载后
  以当前集为中心预取前后各 20 集的预览图；预取有限速、可随时中断，
  上游连续失败时会自动停止，其余仍按需获取。

### 8.6 缓存与过期

- 本地核心会缓存样本索引，避免每次拖动都重新探测；具体位置由客户端管理。
- `expires_at` 是 Unix 秒；过期后客户端会重新调用 `/play`。
- 源可以按需给更短的有效期。

### 8.7 本地解密器 DLL 标准（可选）

如果源需要**客户端本地解密**（而不是自己解密后输出明文），可以随源发布一个
编译好的解密器 DLL。客户端在拉取源时按 manifest 下载、校验并安装它。

#### 8.7.1 发布与下载

manifest 的 `decryptors` 是一个数组：

```json
{
  "decryptors": [
    {
      "id": "builtin:cenc-ctr",
      "algorithms": ["cenc-ctr"],
      "abi": 1
    },
    {
      "id": "sample-cenc",
      "version": "1.0.0",
      "os": "windows",
      "arch": "x86_64",
      "url": "https://downloads.example.test/cenc_decrypt-1.0.0.dll",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "size": 245760,
      "algorithms": ["cenc-ctr"],
      "abi": 1,
      "file": "cenc_decrypt.dll"
    }
  ]
}
```

客户端行为：

1. 只在 `os`/`arch` 与当前平台匹配时下载。
2. 支持 `http://` 和 `https://`；公网/不可信网络建议 HTTPS。HTTP 下 SHA-256 只能防传输损坏，
   不能防 manifest 被篡改，建议通过可信渠道固定 hash。
3. 下载后校验 `size` 与 `sha256`；不匹配则丢弃，不加载。
4. 安装到 `decryptors/<id>/<version>/<file>`，并写一份 `*.json` 描述。
5. 同一个 `id + version + sha256` 已存在时直接复用。
6. 下载失败不阻塞浏览；播放时报告 `40410`（decryptor missing）。

> 安全提示：这是**可执行代码**。manifest 必须固定 `sha256`；不要使用可变 URL 或
> 「latest」覆盖已安装版本。客户端不应在没有哈希校验的情况下加载任何 DLL。

#### 8.7.2 文件与加载位置

- Windows x64：文件名为 `cenc_decrypt.dll`。
- 可在构建时用 `--dart-define=FREEPLAYER_CENC_DLL=<name>` 覆盖。
- 客户端安装包**不再内置任何解密器**。DLL 由源 manifest 声明，客户端按需下载。
- 客户端按以下顺序查找：
  1. `decryptors\<id>\<version>\<file>`（manifest 下载安装位置，递归查找，取最新）
  2. 可执行文件旁的 `decryptors\<name>`（仅开发调试时手动放置）
  3. 可执行文件目录、当前工作目录、开发构建目录（仅开发调试）
- 每个源只使用自己 manifest 里声明的解密器；客户端不会把 A 源的 DLL 用到 B 源上。
  如果两个源需要同一个 DLL，使用相同的 `id + version + sha256` 即可复用；内容不同时
  必须换 `id` 或 `version`，否则会互相覆盖。
- 分发整个本地核心时，核心 DLL 使用另一组入口（`FPCoreStart` / `FPCorePort` /
  `FPCoreError` / `FPCoreStop`），由客户端在启动时加载（见 2.4）；本文的 `fp_cenc_*` 标准针对
  **视频解密模块**。

manifest 中的声明：

```json
{
  "decryptors": [
    {
      "id": "sample-cenc",
      "version": "1.0.0",
      "os": "windows",
      "arch": "x86_64",
      "url": "https://downloads.example.test/cenc_decrypt-1.0.0.dll",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "size": 245760,
      "algorithms": ["cenc-ctr"],
      "abi": 1,
      "file": "cenc_decrypt.dll"
    }
  ]
}
```

客户端下载并校验 `sha256`/`size` 后，把文件放到加载器能找到的位置。
`id + version + sha256` 相同的文件直接复用。

#### 8.7.3 DLL ABI（与客户端一致）

```c
#include <stdint.h>

/* 解析包含 moov 的文件窗口，返回不透明索引句柄；失败返回 NULL。 */
void* fp_cenc_index_create(
    const uint8_t* data, int32_t len,
    int64_t base, int64_t file_size);

/* 把 [start,end] 扩展到完整样本边界；成功返回 0。 */
int32_t fp_cenc_index_span(
    void* index, int64_t start, int64_t end,
    int64_t* out_start, int64_t* out_end);

/* 文件总大小与 moov 结束偏移；失败返回 -1。 */
int64_t fp_cenc_index_size(void* index);
int64_t fp_cenc_index_moov_end(void* index);

/* 原地解密 data；start 是这段数据在文件中的绝对偏移。
 * key 为 16 字节内容密钥；成功返回 0。 */
int32_t fp_cenc_decrypt(
    void* index,
    const uint8_t* key, int32_t key_len,
    uint8_t* data, int32_t data_len,
    int64_t start);

void fp_cenc_index_free(void* index);

/* 最近一次错误的静态文本；没有错误时返回空串。 */
const char* fp_cenc_last_error(void);
```

调用时序：

1. 宿主先探测文件头/尾部，找到包含 `moov` 的窗口；
2. `fp_cenc_index_create(window, len, base, file_size)` 建立样本索引；
3. 播放器请求 `Range` 时，`fp_cenc_index_span` 把字节区间扩展到样本边界；
4. 宿主只向上游取这段密文；
5. `fp_cenc_decrypt(index, key, data, len, span_start)` 原地解密；
6. 宿主输出明文 MP4；
7. 索引不再使用时 `fp_cenc_index_free`。

#### 8.7.4 参数与错误

- `key_len` 必须为 `16`（CENC-AES-CTR）；其他长度返回错误。
- `base`/`start` 是**文件绝对偏移**，不是窗口内偏移。
- `fp_cenc_decrypt` 必须原地修改 `data`，不得改变长度。
- `fp_cenc_index_span` 必须把区间扩到完整样本；否则 AES-CTR 计数器会错位。
- 所有函数返回 `int32_t`/指针；`0` 表示成功，非 `0` 表示失败。
- `fp_cenc_last_error()` 返回静态字符串；调用方不释放。
- 句柄只在创建它的线程内使用；跨线程必须由宿主加锁。
- 不得抛出异常；内部捕获所有错误。

错误码（建议）：

| 值 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 参数非法 |
| `2` | 不支持的容器/方案 |
| `3` | 解密失败 |
| `4` | 内存不足 |
| `5` | 内部错误 |
| `6` | 未初始化/索引损坏 |

#### 8.7.5 安全与实现要求

- 不得访问网络、文件、注册表、环境变量或启动进程。
- 不得记录密钥、明文或用户标识。
- 必须对所有输入做边界检查；不得越界读写。
- 不得把 C++ 异常、STL 类型跨 ABI 传递。
- 建议启用 `/guard:cf`、`/DYNAMICBASE`、`/NXCOMPAT`。
- 发布前用固定测试向量做已知答案测试，并对畸形输入做 fuzz。
- 版本升级必须换 `version` 和 `sha256`；不要原地覆盖已安装文件。

#### 8.7.6 最小实现骨架

```c
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static const char* g_error = "";

typedef struct { int64_t size; int64_t moov_end; } fp_cenc_index;

void* fp_cenc_index_create(const uint8_t* data, int32_t len,
                      int64_t base, int64_t file_size) {
  (void)data; (void)len; (void)base;
  fp_cenc_index* index = (fp_cenc_index*)calloc(1, sizeof(fp_cenc_index));
  if (!index) { g_error = "out of memory"; return NULL; }
  index->size = file_size;
  index->moov_end = 0; /* TODO: 解析 moov */
  return index;
}

int32_t fp_cenc_index_span(void* handle, int64_t start, int64_t end,
                      int64_t* out_start, int64_t* out_end) {
  if (!handle || !out_start || !out_end || start < 0 || end < start) {
    g_error = "invalid argument";
    return 1;
  }
  /* TODO: 按样本表扩展区间 */
  *out_start = start;
  *out_end = end;
  return 0;
}

int64_t fp_cenc_index_size(void* handle) {
  return handle ? ((fp_cenc_index*)handle)->size : -1;
}

int64_t fp_cenc_index_moov_end(void* handle) {
  return handle ? ((fp_cenc_index*)handle)->moov_end : -1;
}

int32_t fp_cenc_decrypt(void* handle, const uint8_t* key, int32_t key_len,
                   uint8_t* data, int32_t data_len, int64_t start) {
  (void)start;
  if (!handle || !key || key_len != 16 || !data || data_len < 0) {
    g_error = "invalid argument";
    return 1;
  }
  /* TODO: 按样本解密 data；示例只做占位。 */
  return 0;
}

void fp_cenc_index_free(void* handle) { free(handle); }
const char* fp_cenc_last_error(void) { return g_error; }
```

构建（Windows x64）：

```bat
cl /LD /O2 /guard:cf /DYNAMICBASE /NXCOMPAT ^
   cenc_decrypt.c /link /DEF:cenc_decrypt.def
```

`.def` 必须导出全部 `fp_cenc_*` 符号，且不要做名称修饰：

```def
EXPORTS
  fp_cenc_index_create
  fp_cenc_index_span
  fp_cenc_index_size
  fp_cenc_index_moov_end
  fp_cenc_decrypt
  fp_cenc_index_free
  fp_cenc_last_error
```

## 9. 认证与账号

### 9.1 原则

- 登录态可以两种方式存在，**都支持**：
  1. **源侧会话**：token/cookie 只存在源/网关，客户端只拿展示字段；
  2. **客户端持有**：源在登录响应的 `credentials` 里返回 token/cookie，客户端后续请求自动带上。
- **不要返回明文密码**；密码只用于源侧校验。token/cookie 可以返回（见 9.2/9.4）。
- 登录方式、字段、按钮文案、成功提示全部由源声明；客户端不假设一定有二维码或短信。
- 需要登录的端点返回 `40100`；客户端会引导登录。
- 账号能力通过 `capabilities` 里的 `auth` 声明；没有 `auth` 时客户端不显示账号入口。

### 9.2 自定义登录（任意语言都可实现）

源在 manifest 的 `auth.login` 里描述自己的登录 UI，并可用
`credential_header` / `credential_prefix` 告诉客户端怎么带 token：

```json
{
  "auth": {
    "required": true,
    "methods": ["form"],
    "credential_header": "Authorization",
    "credential_prefix": "Bearer ",
    "login": {
      "title": "示例登录",
      "description": "凭证只会发送到你的网关。",
      "method": "form",
      "submit_label": "登录",
      "fields": [
        {
          "key": "username",
          "label": "账号",
          "type": "text",
          "required": true,
          "placeholder": "demo"
        },
        {
          "key": "password",
          "label": "密码",
          "type": "password",
          "required": true
        }
      ],
      "success_fields": ["user_id", "name", "avatar", "credentials"]
    }
  }
}
```

登录成功可以返回任意字段，凭证放在 `credentials`：

```json
{
  "logged_in": true,
  "user_id": "u-1",
  "name": "示例用户",
  "avatar": "",
  "credentials": {
    "token": "opaque-token",
    "cookie": "session=opaque-cookie",
    "expires_at": 1793391642
  }
}
```

规则：

- `method`：`form`（默认）、`cookie`、`token`、`qrcode`、`sms`、`external`。
- `fields[].type`：`text`、`password`、`tel`、`email`、`textarea`。
- `fields` 非空时，客户端渲染通用表单并 `POST /auth/login`；二维码/短信 UI 不再出现。
- `fields` 为空且 `method` 为 `qrcode`/`sms` 时，客户端使用下面的内置流程。
- `success_fields` 是给源自己的文档；客户端只依赖 `user_id`、`name`、`avatar` 做展示。
- **可以返回 token/cookie**：放 `credentials.token` / `credentials.cookie`；
  客户端默认带 `Authorization: Bearer <token>`，可用 manifest 的
  `credential_header`/`credential_prefix` 或 `credentials.header`/`credentials.prefix` 覆盖。
- **不要返回明文密码**；如果必须回传密码才能直连上游，请改为在源侧换取短期 token。

### 9.3 端点

| 方法 | 路径 | 请求 | 响应 |
|---|---|---|---|
| POST | `/auth/login` | `{"method","fields":{...}}` | `{"logged_in":true,"user_id","name","avatar","credentials":{...}, ...自定义字段}` |
| GET | `/auth/qrcode` | — | `{"token","image","expire_at","status"}` |
| GET | `/auth/qrcode/status?token=` | — | `{"status":"new/scanned/confirmed/expired"}` |
| POST | `/auth/sms/send` | `{"mobile"}` | `{"ok":true}` |
| POST | `/auth/sms/login` | `{"mobile","code"}` | `{"user_id","name","avatar","credentials":{...}}` |
| GET | `/auth/me` | — | `{"user_id","name","avatar","logged_in":true}` |
| POST | `/auth/logout` | — | `{"ok":true}` |

`image` 可以是 data URL 或 base64；客户端会解码显示。

### 9.4 凭证与会话

- **源侧会话**：源把 token/cookie 写进自己的存储（文件、数据库、内存均可），
  客户端只拿展示字段；`/auth/me` 是登录态的唯一判断。
- **客户端持有**：源把 token/cookie 放进 `credentials`；客户端在本次会话内保存，
  并自动附加到该源后续请求（默认 `Authorization: Bearer`，可配置）。
  客户端不会展示或记录它。
- 两种模式可以同时存在：源既保存会话，也返回 token 供客户端校验。
- 如果客户端需要跨重启保留 token，源应提供长期有效的会话或刷新接口；
  客户端不应把明文 token 写进普通配置文件。
- 切换源时客户端会清空上一个源的凭证；源不应复用别的源的会话。
- HTTP 和 HTTPS 都支持。loopback、局域网、自建可信环境可以直接用 HTTP；
  公网或不可信网络建议 HTTPS，因为 token/cookie 会在请求头里传输。
- token 要短 TTL、可撤销；HTTP 部署时不要在日志里打印请求头。

### 9.5 登录文案

登录弹层的全部文案来自 `ui.labels` 的 `login.*` 键（见 6.3）。缺失时使用中性兜底，
不会出现任何产品名或外部 App 名。源应提供：

- `login.title`、`login.description`（可选）
- `login.steps`（`\n` 分隔）
- 各按钮与状态提示
- 自定义表单的 `login.required`

### 9.6 实现方式

在源列表响应的 manifest 里写 `auth.login`，并实现 `POST /auth/login`
（路径可以按 3.5 的 `endpoints.auth_login` 自定义）。

请求体是 `{"method","fields":{...}}`，源返回的 map 原样作为 `data` 下发；
不要包含明文密码；token/cookie 放在 `credentials` 里。示例已包含在
`python_gateway_example.py`。

---

## 10. 测试与验收

### 10.1 分层测试

| 层 | 测什么 | 工具 |
|---|---|---|
| 映射单测 | 上游 JSON → 协议 DTO | 各语言自带测试框架；用固定 fixture |
| 协议单测 | 分页、错误码、空查询、未知 ID | requests / httptest / urllib + 本地服务 |
| 端到端 | 客户端真实链路 | 启动源，客户端连接 |
| 一致性 | 9 组协议检查 | `protocol_check.py`（随本文提供） |

### 10.2 一致性测试

[`protocol_check.py`](source-dev/protocol_check.py) 只依赖 Python 标准库，会读取 manifest
的 `endpoints`，因此对任意路径、任意语言的源都适用：

```bash
# 默认入口：<base>/v1/sources
python docs/source-dev/protocol_check.py --base http://127.0.0.1:8790

# 入口是任意路径时：直接给源列表 URL
python docs/source-dev/protocol_check.py \
  --sources-url http://127.0.0.1:8790/v1/xxx/sources_test.php

# 可选：指定源 ID 和搜索词
python docs/source-dev/protocol_check.py --base http://host --source demo --q 示例
```

检查项：

- 源列表信封与 `protocol == "1"`
- `/ui` 页面类型在 `X-Client-Pages` 内
- `/feed` 至少一条
- `/search`（传入 `--q` 时）
- `/detail`、`/episodes`、`/play`
- asset Range：`206` 且前 12 字节含 `ftyp`
- 未知 detail 返回 `40400`

> 多源时只检查 `--source` 指定的源（默认第一个）。路径映射、下载解密器等
> 客户端行为仍需在真实客户端里验收。

### 10.3 手工验收矩阵

| 场景 | 期望 |
|---|---|
| 空搜索 `q=` | `code 0`、`items: []`，不是错误 |
| 未知详情 | `40400` |
| 未知源 ID | `40400` |
| 未实现的可选端点 | `50100` |
| 缺 `episode_id` 的 `/play` | `40001` |
| 上游超时 | `50010`（或 HTTP 504） |
| 分页到最后一页 | `next: ""`、`has_more: false` |
| Range `bytes=0-255` | `206`、`Content-Range`、256 字节 |
| Range 超出文件 | `416` |
| 封面为空 | 客户端显示渐变占位，不报错 |
| `/ui` 只返回部分页面 | 客户端只显示白名单内的菜单 |

### 10.4 Definition of Done

- [ ] `GET /v1/sources` 能被客户端识别，`protocol` 为 `"1"`
- [ ] `/ui` 只返回封闭页面类型，且遵守 `X-Client-Pages`
- [ ] 首页能滚动/切换标签，`channel` 由源决定
- [ ] 搜索非空有结果，空查询返回空页
- [ ] 详情 + 选集能打开
- [ ] `/play` 返回至少一条流，客户端能起播
- [ ] asset 支持 Range，拖动进度条可用
- [ ] 未知条目返回 `40400`
- [ ] 未实现的可选能力返回 `50100`
- [ ] 所有上游调用带超时，且能被取消
- [ ] 大整数 ID 保持字符串精度
- [ ] 协议自检通过（见 10.2）

---

## 11. 红线与常见错误

### 11.1 红线

1. **不要把上游域名、CDN 直链、签名密钥、设备档案写进客户端。**
2. **不要把明文密码返回给客户端。** token/cookie 可以通过登录响应的 `credentials` 显式返回，但不得写日志。
3. **不要发明页面类型；不要返回客户端不认识的 `page`。**
4. **不要猜上游常量。** 每个常量至少要有：抓包/线上响应、官方文档、反汇编/字节码证据之一。
5. **不要用 `float64` 承载大整数 ID。** 19 位 ID 会丢精度；统一用字符串或 `json.Number`。
6. **不要为 Range 请求整文件下载。** 要么按区间取，要么本地切片。
7. **不要返回永远前进不了的 `next`。** 会造成无限加载。
8. **不要在源里写死客户端的菜单文案。** 文案属于源 manifest，不属于壳。

### 11.2 常见错误

| 现象 | 原因 | 修复 |
|---|---|---|
| 客户端显示「该源不支持此页面」 | 返回了 `50100` 或未知 `page` | 实现对应端点，或从 manifest 移除 |
| 首页空白 | `/feed` 返回空 `items` 或错误码 | 检查 `channel` 映射与上游 |
| 详情页一直加载 | `/detail` 超时或字段缺失 | 加超时；确保 `id`/`item_id`/`title` |
| 播放黑屏 | asset 不支持 Range 或 Content-Type 错误 | 返回 206 + `video/mp4` |
| 拖动进度条失败 | `Content-Range` 不匹配或 200 而非 206 | 修正 Range 逻辑 |
| 搜索报错 | 空 `q` 返回了错误 | 空查询返回空页 |
| 菜单缺失 | `/ui` 页面类型拼错 | 对照 6.1 的封闭集合 |
| 列表重复/死循环 | `next` 永远非空 | 最后一页返回空 `next` |
| 客户端显示旧的文案/标签 | 客户端缓存了旧 manifest | 重新拉取 UI manifest 或重启客户端 |
| 本地核心启动失败 / 端口被占用 | 写死了固定端口 | 改用 `127.0.0.1:0`，通过桥接接口读取实际端口（见 2.3） |
| 独立源服务换了端口后客户端连不上 | 客户端还在用旧地址 | 用实际端口重新添加地址；源列表 URL 才是入口 |

---

## 12. AI Agent 开发协议

本节的目标是让 Agent 在**不猜测**的前提下完成一个源。建议把下面这份任务单交给 Agent，
并把上游 fixture（脱敏后的 JSON 响应）一起给它。

### 12.1 输入材料

Agent 至少需要：

1. 上游接口文档或抓包（脱敏；不要放真实 token）。
2. 每个接口的示例响应（`testdata/upstream/*.json`）。
3. 字段映射表（上游字段 → 协议字段）。
4. 媒体类型：明文 MP4 / HLS / DASH / 加密 MP4。
5. 验收目标：要支持哪些页面（首页/搜索/详情/榜单/分类/账号）。

### 12.2 机器可读任务单

模板见 [`docs/source-dev/agent-task.example.json`](source-dev/agent-task.example.json)。
核心字段：

```json
{
  "task": "implement_source",
  "source_id": "demo",
  "protocol": "1",
  "language": "python",
  "topology": "standalone_gateway",
  "upstream": {
    "base_url_env": "DEMO_BASE_URL",
    "fixtures_dir": "testdata/upstream",
    "auth": "none"
  },
  "required_pages": ["home.feed", "search", "detail", "player"],
  "endpoints": {
    "search": { "upstream": "/search", "method": "GET" },
    "detail": { "upstream": "/item/{id}", "method": "GET" },
    "episodes": { "upstream": "/item/{id}/episodes", "method": "GET" },
    "play": { "upstream": "/item/{id}/play", "method": "POST" }
  },
  "media": { "kind": "plain_mp4", "range": true },
  "acceptance": [
    "empty search returns code 0 with zero items",
    "unknown detail returns 40400",
    "play returns at least one stream",
    "asset returns 206 for bytes=0-255"
  ],
  "constraints": [
    "never expose upstream URLs; tokens/cookies may only appear in the login credentials object",
    "use sample data in tests, never production identifiers",
    "preserve 64-bit ids as strings",
    "every upstream call has a timeout"
  ]
}
```

### 12.3 Agent 工作循环

1. **读契约**：先读本文第 3–8 节，列出必须实现的端点。
2. **建 fixture**：把上游响应脱敏后放进 `testdata/upstream/`。
3. **写映射**：先写纯函数 `map_item` / `map_episode` / `map_play`，用 fixture 做单测。
4. **接 HTTP**：按第 5 节实现路由与信封。
5. **接媒体**：先做明文 Range；需要解密时再引入 CENC。
6. **跑验收**：按 10.3 的矩阵逐条验证，记录实际响应。
7. **交差**：给出端点清单、测试结果、未实现项（必须是 `50100`，不能静默返回空）。

### 12.4 可直接复制的提示词

```text
你要为 SourceProtocol v1 实现一个内容源。

先阅读：
- docs/SOURCE_DEVELOPMENT.md（协议、字段、页面类型、红线）
- docs/source-dev/python_gateway_example.py（可运行骨架）
- docs/source-dev/agent-task.example.json（任务单模板）
- testdata/upstream/*.json（脱敏后的上游响应）

规则：
1. 不要猜测上游字段；只使用 fixture 或文档中出现的字段。
2. 不要让上游 URL 出现在客户端；token/cookie 只能在登录响应的 `credentials` 中显式返回，且不得记录。
3. 页面类型只能从 SOURCE_DEVELOPMENT.md 6.1 的封闭集合里选。
4. 空搜索返回 code 0 + 空 items；未知条目返回 40400；未实现能力返回 50100。
5. 大整数 ID 用字符串。
6. 所有上游请求带超时。
7. 不要修改客户端代码。

交付：
- 源服务代码（任意语言）
- testdata/upstream 的 fixture 与映射单测
- 一份端点自检结果（curl 或测试输出）
- 未实现项清单
```

### 12.5 Agent 验收 JSON

Agent 结束时输出：

```json
{
  "source_id": "demo",
  "implemented": ["sources", "ui", "feed", "search", "detail", "episodes", "play", "asset"],
  "not_implemented": ["rank", "comments"],
  "tests": {
    "unit": "pass",
    "conformance": "pass",
    "manual_matrix": "pass"
  },
  "known_gaps": [
    "cover URLs are public; no proxy",
    "no auth"
  ]
}
```

---

## 13. 附录：示例响应与字段表

### A. `/v1/meta`

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "name": "Demo Source Gateway",
    "version": "1.0.0",
    "protocol": "1",
    "source_count": 1,
    "limits": { "rpm": 600 }
  },
  "trace_id": "a1b2c3d4"
}
```

### B. `/v1/{sid}/feed`

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "source": "demo",
        "id": "demo-1",
        "item_id": "demo-1",
        "type": "series",
        "title": "示例剧集：第一季",
        "cover": "",
        "description": "用于演示详情、选集与播放链路。",
        "episode_count": 3,
        "tags": ["示例", "剧情"],
        "badges": ["示例"],
        "extra": { "vid": "demo-1-ep1", "episode_count": 3 }
      }
    ],
    "next": "",
    "next_cursor": "",
    "has_more": false,
    "total": 1
  },
  "trace_id": "b2c3d4e5"
}
```

### C. `/v1/{sid}/episodes/{id}`

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "item_id": "demo-1",
    "items": [
      {
        "episode_id": "demo-1-ep1",
        "id": "demo-1-ep1",
        "index": 1,
        "title": "第 1 集",
        "duration_sec": 8,
        "duration_ms": 8000,
        "extra": {}
      }
    ],
    "episodes": [
      {
        "episode_id": "demo-1-ep1",
        "id": "demo-1-ep1",
        "index": 1,
        "title": "第 1 集",
        "duration_sec": 8,
        "duration_ms": 8000,
        "extra": {}
      }
    ],
    "next": "",
    "next_cursor": "",
    "has_more": false
  },
  "trace_id": "c3d4e5f6"
}
```

### D. `/v1/{sid}/play`

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "source": "demo",
    "item_id": "demo-1",
    "episode_id": "demo-1-ep1",
    "title": "示例剧集：第一季 第 1 集",
    "duration_ms": 8000,
    "streams": [
      {
        "id": "720p",
        "quality": "720p",
        "protocol": "http",
        "container": "mp4",
        "codec": "h264",
        "width": 720,
        "height": 1280,
        "mime_type": "video/mp4",
        "url": "http://127.0.0.1:8790/v1/demo/asset/<opaque-token>"
      }
    ],
    "next_episode_id": "demo-1-ep2",
    "downgraded": false,
    "expires_at": 1793391642
  },
  "trace_id": "d4e5f6a7"
}
```

### E. 错误响应

```json
{
  "code": 40400,
  "message": "item not found",
  "data": null,
  "trace_id": "e5f6a7b8"
}
```

### F. 推荐的项目结构

源可以用任何语言、任何框架，下面只是建议：

```text
your-source/
  app.py | index.php | server.js | main.go   ← 入口：监听一个 HTTP 端口
  routes/                                     ← 源列表、UI、搜索、详情、播放、asset
  upstream/                                   ← 上游 HTTP 客户端（可选）
  testdata/upstream/                          ← 脱敏后的上游响应
  tests/                                      ← 映射单测与协议自检
  README.md                                   ← 启动方式、环境变量、已知限制
```

配套示例：

```text
docs/source-dev/
  python_gateway_example.py    ← 可运行的最小网关
  protocol_check.py            ← 语言无关的协议自检
  agent-task.example.json      ← Agent 任务单模板
```

### G. 术语表

| 术语 | 含义 |
|---|---|
| 源 / source | 一个内容提供方，有一个稳定的 `id` |
| manifest | 源的能力声明（`/v1/sources`、`/ui`） |
| UI manifest | 菜单与文案数据，客户端按此渲染 |
| item | 一部剧/一个条目 |
| episode | 一集 |
| asset | 源签发的媒体 URL，对客户端不透明 |
| cursor | 分页游标，对客户端不透明 |
| CENC | ISO Common Encryption，按样本的 AES-CTR |
| Range | HTTP 字节区间请求，播放器拖动依赖它 |
| 50100 | 「不知道/不支持」，客户端会降级 |
