# netFixWithclashVR

Clash Verge Rev 网络修复 + 性能调优工具，支持 Windows 和 macOS。

## 解决什么问题

| 症状 | 根因 | 修复方式 |
|------|------|---------|
| 代理速度远低于另一台电脑 | TUN stack=gvisor（用户态处理慢）| → mixed（TCP 内核加速）|
| 同上 | TUN MTU=1500（分片开销大）| → 9000（本地虚拟设备无需受限）|
| 同上 | tcp-concurrent 未启用 | → 启用（DNS 并发解析）|
| 同上 | keep-alive 未配置 | → 30s（减少连接重建）|
| 关了 Clash 还能翻墙 | service/TUN 进程残留 | 彻底杀进程 + 重装服务 |
| 节点选美国但出口 IP 显示 HK | Merge profile 覆盖了机场 DNS | 不覆盖 DNS，保留机场智能 DOH |
| Cursor 无法使用 Claude 模型 | cursor.sh 等域名未走 AI 分流 | 注入 DOMAIN-SUFFIX 规则 |
| WiFi 速度波动大 | IPv6 双栈延迟 + 频段无首选 + 节能 | 禁 IPv6 + 优先 5GHz + 最大性能 |
| Clash API 不响应 | 服务故障, sidecar fallback | 重装服务 + prefer_sidecar=false |

## 文件说明

```
fix_clash_windows.ps1   # Windows 修复脚本（PowerShell, 需管理员）
fix_clash_macos.sh      # macOS 修复脚本（Bash, 需 sudo）
README.md               # 本文件
```

## 使用方法

### Windows

```powershell
# 方式 1: 右键 fix_clash_windows.ps1 → "使用 PowerShell 运行"（自动提权）
# 方式 2: 管理员 PowerShell 中执行:
Set-ExecutionPolicy Bypass -Scope Process -Force
.\fix_clash_windows.ps1

# 仅诊断不修复:
.\fix_clash_windows.ps1 -DiagnoseOnly

# 修复但不自动启动 Clash:
.\fix_clash_windows.ps1 -SkipRestart
```

### macOS

```bash
chmod +x fix_clash_macos.sh
sudo ./fix_clash_macos.sh              # 完整诊断 + 修复
sudo ./fix_clash_macos.sh --diagnose   # 仅诊断
sudo ./fix_clash_macos.sh --kill       # 仅停止 Clash
```

## 脚本执行流程

```
诊断阶段 (两平台通用):
  ├─ 检查 Clash 进程 & 服务状态
  ├─ 检查 TUN 虚拟网卡 & 路由表
  ├─ 检查运行时配置 (stack / MTU / tcp-concurrent)
  ├─ 检查 DNS 配置 (是否覆盖了机场 DOH)
  ├─ 检查系统代理 / IPv6 / WiFi 设置
  └─ 检测出口 IP & 连通性

修复阶段:
  ├─ 彻底停止 Clash 所有组件
  ├─ [Win] 重装 Clash 系统服务
  ├─ 修复 verge.yaml (service 模式, DNS 设置关闭)
  ├─ 优化 config.yaml (TUN stack=mixed, MTU=9000)
  ├─ 优化 Merge Profile (tcp-concurrent, keep-alive, sniffer; 不覆盖 DNS)
  ├─ 注入 Cursor/Claude 分流规则
  ├─ [Win] TCP 优化 (AutoTuning, RSC, FastOpen, Timestamps)
  ├─ [Win] WiFi 优化 (5GHz 优先, 吞吐量增强, 电源最大性能)
  ├─ 禁用 IPv6 / 清除系统代理 / 刷新 DNS
  └─ 启动 Clash Verge Rev & 验证
```

## 关键技术细节

### 为什么不能覆盖机场 DNS？

机场（如 Nexitally）的订阅配置包含**专属 DOH 服务器**（如 `wrecking7857.com:44443`），这些 DOH 服务器会将代理服务器主机名解析到**最优中转节点**。如果用通用 DNS（如 `223.5.5.5`）覆盖，代理服务器会被解析到**次优中转**（如日本/香港），导致：
- 出口 IP 不在预期地区
- 速度下降（多走一跳）

### TUN stack 选择

| Stack | TCP | UDP | 适用场景 |
|-------|-----|-----|---------|
| gvisor | 用户态 | 用户态 | 兼容性最好，性能最差 |
| system | 内核态 | 内核态 | 性能好，部分系统不兼容 |
| **mixed** | **内核态** | **用户态** | **推荐：TCP 快 + UDP 兼容** |

### config.yaml vs Merge Profile

Clash Verge Rev 的 TUN 参数优先级：`config.yaml` > Merge Profile。因此 `stack` 和 `mtu` 必须在 `config.yaml` 中修改才能生效。而 `tcp-concurrent`、`keep-alive`、`sniffer` 等顶层参数通过 Merge Profile 生效。

## 修复后手动操作

1. 在 Clash Verge Rev UI 中确认 **TUN 模式**已开启
2. 将 **AI / Proxies / Final** 代理组切到**同一个美国节点**
3. 浏览器访问 `https://ipinfo.io/json` 确认 `country` 为 `US`
4. 如果所有美国节点出口仍为 HK，这是**机场中转架构**问题，非客户端可修复

## 许可

MIT
