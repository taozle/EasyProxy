# EasyProxy

iOS / macOS 上的轻量代理服务器，基于 SwiftNIO 构建。同一端口同时支持 HTTP 代理和 SOCKS5 代理（含 UDP ASSOCIATE）。

## 功能

- **HTTP Forward Proxy** — 转发 `GET`/`POST` 等明文 HTTP 请求
- **HTTPS CONNECT Tunnel** — 建立 TCP 隧道，透传 TLS 流量
- **SOCKS5 CONNECT** — RFC 1928 TCP 代理
- **SOCKS5 UDP ASSOCIATE** — RFC 1928 UDP 转发
- **自动协议检测** — 首字节嗅探，单端口 (8080) 同时服务 HTTP 与 SOCKS5
- **屏幕常亮** — 可选开关，防止 iOS 息屏断联
- **连接并发控制** — 可配置上限，超限返回 503
- **实时统计** — 活跃连接、SOCKS5 连接数、UDP 包转发量等

## 要求

- Xcode 15+
- iOS 16.0+ / macOS 13.0+
- Swift 5.9+

## 开始使用

1. 克隆仓库：

```bash
git clone git@github.com:taozle/EasyProxy.git
cd EasyProxy
```

2. 配置签名：

```bash
cp Local.xcconfig.example Local.xcconfig
```

编辑 `Local.xcconfig`，填入你的 Apple Development Team ID：

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

3. 用 Xcode 打开 `EasyProxy.xcodeproj`，选择目标设备，运行。

## 验证

启动后，UI 上会显示设备的 WiFi IP 和端口。在同一局域网的电脑上测试：

```bash
# HTTP 代理
curl -x http://<ip>:8080 http://httpbin.org/ip

# HTTPS 代理（CONNECT 隧道）
curl -x http://<ip>:8080 https://httpbin.org/ip

# SOCKS5 TCP
curl --socks5-hostname <ip>:8080 https://httpbin.org/ip
```

## 配置

编辑 `EasyProxy/ProxyConfig.swift`：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `port` | 8080 | 监听端口 |
| `maxConcurrentConnections` | 1024 | 最大并发连接数 |
| `connectTimeoutSeconds` | 8 | 上游连接超时（秒） |
| `idleTimeoutSeconds` | 120 | 空闲超时（秒） |
| `maxRecentErrors` | 50 | UI 显示的最近错误条数 |
| `udpRelayTimeoutSeconds` | 120 | UDP 会话超时（秒） |
| `maxUDPOutboundChannels` | 256 | UDP 出站通道上限 |

## 架构

```
客户端连接 (port 8080)
    │
    ▼
ProtocolDetectorHandler ── 首字节嗅探
    │
    ├─ ASCII ──▶ HTTP Codec → ProxyHandler
    │               ├─ CONNECT  → GlueHandler（双向 TCP 隧道）
    │               └─ GET/POST → UpstreamRelayHandler（转发响应）
    │
    └─ 0x05 ──▶ SOCKS5Handler
                    ├─ CMD=CONNECT       → GlueHandler（复用）
                    └─ CMD=UDP ASSOCIATE → UDPRelaySession
                                            ├─ InboundHandler（解析 → 转发）
                                            └─ OutboundHandler（封装 → 回传）
```

## 依赖

- [swift-nio](https://github.com/apple/swift-nio) — 异步网络 I/O
- [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) — iOS Network.framework 集成
- [swift-log](https://github.com/apple/swift-log) — 日志

## License

MIT
