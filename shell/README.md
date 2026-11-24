# Free Player

通用播放器壳，只实现 SourceProtocol v1，不含任何源逻辑（PRD §1.2、§5.5）。

- 官网：<https://freeplayer.8a5.cn>
- 开源仓库：<https://github.com/net900/freeplayer>
- 许可证：[MIT](LICENSE)

## 状态

- 可运行的 Flutter Windows 骨架：首启、主框架、菜单渲染、11 种页面类型入口、设置页。
- 播放内核 `media_kit`，本地源 JS 运行时 `flutter_js`（QuickJS）。
- `lib/` 内不出现源名、域名、签名常量或业务菜单文案；菜单来自 `ui_manifest`。

## 开发

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

国内网络建议先设置镜像：

```bash
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

## 添加源

源页面用自适应网格列出已经添加的源和「本机视频」，标题右侧只有一个「添加源」按钮。源多时网格自动换行，页面滚动；添加入口始终在顶部。推荐源默认显示在网格上方，右上角的关闭按钮会隐藏它，并把选择保存到 `settings.json`；隐藏后可以用「显示官方推荐源」重新打开。

旧版本预置的 555 和红果只会在首次启动时清理一次。现在红果由内嵌核心提供：安装红果源时下载核心，启动时只静默检查更新（SHA 不变就不下载），删除源时一并删除核心 DLL。

点开「添加源」只需要填写地址：

- 普通网关地址按线上源添加，名称、菜单和能力仍由源自己的 manifest 提供。
- 以 `.js` 结尾的地址会作为本地源安装，见下一节。
- 站点整理的源显示在源页面的「官方推荐源」里，点一次即可添加。

「本机视频」不是内容源，但和源使用同样大小的卡片，点击后进入本机文件模式。

默认请求线上站点 `https://freeplayer.8a5.cn/api/sources?featured=1`。本地调试时改成开发服务：

```bash
flutter run -d windows --dart-define=FP_RECOMMENDED_SOURCES_URL=http://127.0.0.1:8090/api/sources?featured=1
```

## 本地 JS 源

源分为两类：

- **线上源**：普通 HTTP 网关，客户端通过 `GatewayClient` 访问。
- **本地源**：云端下发一份 JS 源包，客户端下载并校验 SHA-256 后存入本机，在内置 QuickJS 中执行。不会启动 PHP、Node 或任何可执行文件。

本地源的抓取、播放列表校验和 HLS 代理由 Dart 完成：

- `lib/core/local_source/local_js_source_api.dart`：加载 JS、调用解析函数、生成 `SourceApi`。
- `lib/core/local_source/local_hls_proxy.dart`：回环 HLS 代理，改写子列表、AES key 和分片。
- `lib/core/local_source/local_sources_service.dart`：下载、校验、安装、启动恢复和删除。

带「本地」标记的源卡在客户端内运行；删除本地源会同时删除本机 JS 文件。推荐源列表在版本变化时显示「更新」。

本地源统一从「添加源 → 本地源」进入，支持：

- 输入 JS 地址，客户端在线读取并安装；
- 直接粘贴脚本内容安装；
- 手动下载 JS 后放进本地源目录，点「扫描目录」；下次启动也会自动扫描该目录。

本地源目录是应用数据目录下的 `local_sources/`，安装弹窗会显示完整路径并提供“打开目录”。

### 动态请求头

源包可以把 `headers` 写成对象（固定请求头），也可以写成函数：

```js
headers: function (ctx) {
  // ctx: { name, url, method }，url 是本次实际要请求的绝对地址
  return { 'X-Sign': sign(ctx.url), 'X-Time': String(Date.now()) };
}
```

写成函数时，客户端在每次请求前调用它，因此签名可以绑定当次的 URL 查询参数和时间戳。
`parsePlay` 可以返回 `{ url, name }`，`name` 会作为清晰度显示。

### 直链播放

默认情况下本地源的播放地址会经过回环 HLS 代理，以便补请求头、改写子列表和 AES key。
源包可以在顶层声明 `direct_media: true`：

```js
var __FP_SOURCE = { ..., direct_media: true };
```

声明后 `parsePlay` 返回的地址会原样交给播放器，客户端不再校验、不再代理、也不转发任何媒体流量；
播放器直接请求上游 CDN。

## 预览

首启页在 debug 构建下提供「开发预览」入口，加载 `assets/dev/demo.json`，
仅用于界面验收，不随产品发布，也不会进入用户的源列表。
预览数据只包含界面文案和占位封面，不携带任何媒体文件：需要试播放时自备一个本地视频。
