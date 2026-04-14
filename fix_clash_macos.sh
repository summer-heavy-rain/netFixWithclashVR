#!/usr/bin/env bash
#
# Clash Verge Rev 网络修复 + 性能调优 (macOS)
#
# 一键诊断并修复 Clash Verge Rev / Mihomo TUN 模式常见网络问题：
#   ① Clash 进程残留
#   ② TUN stack 非最优 (gvisor → mixed)
#   ③ TUN MTU 过小 (1500 → 9000)
#   ④ tcp-concurrent / keep-alive 未启用
#   ⑤ Merge profile 覆盖了机场自带 DNS
#   ⑥ DNS 缓存污染
#   ⑦ Cursor/Claude 缺少 AI 分流规则
#
# 用法:
#   chmod +x fix_clash_macos.sh
#   sudo ./fix_clash_macos.sh              # 完整诊断+修复
#   sudo ./fix_clash_macos.sh --diagnose   # 仅诊断
#   sudo ./fix_clash_macos.sh --kill       # 仅停止 Clash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;37m'; NC='\033[0m'
step_ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
step_warn() { echo -e "  ${YELLOW}[!]${NC}  $1"; }
step_bad()  { echo -e "  ${RED}[X]${NC}  $1"; }
step_info() { echo -e "       ${GRAY}$1${NC}"; }
step_head() { echo -e "\n${CYAN}[$1/$2]${NC} $3"; }

DIAGNOSE_ONLY=false
KILL_ONLY=false
SKIP_RESTART=false
for arg in "$@"; do
    case "$arg" in
        --diagnose) DIAGNOSE_ONLY=true ;;
        --kill)     KILL_ONLY=true ;;
        --skip-restart) SKIP_RESTART=true ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    step_bad "需要 root 权限，请使用 sudo 运行"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
VERGE_DATA="$REAL_HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
CLASH_APP="/Applications/Clash Verge.app"

if [[ ! -d "$VERGE_DATA" ]]; then
    step_bad "未找到 Clash Verge Rev 数据目录: $VERGE_DATA"
    exit 1
fi

TOTAL=12
[[ "$DIAGNOSE_ONLY" == true ]] && TOTAL=7
[[ "$KILL_ONLY" == true ]] && TOTAL=1
S=0

echo ""
echo "================================================"
echo "  Clash Verge Rev 网络修复 + 性能调优 (macOS)"
echo "================================================"
echo "  数据目录: $VERGE_DATA"

# ══════════════════════════════════════════════════════════
#  阶段一：诊断
# ══════════════════════════════════════════════════════════

S=$((S+1)); step_head $S $TOTAL "检查 Clash 进程"
CLASH_UI=$(pgrep -x "Clash Verge" 2>/dev/null || true)
MIHOMO=$(pgrep -x "verge-mihomo" 2>/dev/null || pgrep -f "verge-mihomo" 2>/dev/null || true)
[[ -n "$CLASH_UI" ]] && step_info "Clash Verge UI PID: $CLASH_UI"
[[ -n "$MIHOMO" ]]   && step_info "verge-mihomo   PID: $MIHOMO"
[[ -z "$CLASH_UI" && -z "$MIHOMO" ]] && step_ok "无 Clash 进程运行"

if [[ "$KILL_ONLY" == true ]]; then
    echo ""
    [[ -n "$CLASH_UI" ]] && kill -9 $CLASH_UI 2>/dev/null && step_ok "已停止 Clash Verge UI"
    [[ -n "$MIHOMO" ]]   && kill -9 $MIHOMO 2>/dev/null && step_ok "已停止 verge-mihomo"
    killall -9 "clash-verge-service" 2>/dev/null && step_ok "已停止 clash-verge-service" || true
    echo "完成"; exit 0
fi

S=$((S+1)); step_head $S $TOTAL "检查 TUN 网卡"
TUN_IF=$(ifconfig 2>/dev/null | grep -B1 "198.18." | head -1 | awk -F: '{print $1}' || true)
if [[ -n "$TUN_IF" ]]; then
    step_ok "TUN 网卡: $TUN_IF"
else
    step_warn "未检测到 TUN 网卡 (198.18.x)"
fi

S=$((S+1)); step_head $S $TOTAL "检查运行时配置"
CONFIG_YAML="$VERGE_DATA/config.yaml"
ISSUES=()
if [[ -f "$CONFIG_YAML" ]]; then
    STACK=$(grep -oP 'stack:\s*\K\w+' "$CONFIG_YAML" 2>/dev/null || echo "unknown")
    MTU=$(grep -oP 'mtu:\s*\K\d+' "$CONFIG_YAML" 2>/dev/null || echo "0")
    [[ "$STACK" != "mixed" ]] && { step_bad "TUN stack: $STACK → 应为 mixed"; ISSUES+=("TUN_STACK"); } || step_ok "TUN stack: mixed"
    [[ "$MTU" -lt 9000 ]] && { step_warn "TUN MTU: $MTU → 建议 9000"; ISSUES+=("TUN_MTU"); } || step_ok "TUN MTU: $MTU"
fi

VERGE_YAML="$VERGE_DATA/verge.yaml"
if [[ -f "$VERGE_YAML" ]] && grep -q 'prefer_sidecar:\s*true' "$VERGE_YAML"; then
    step_bad "运行在 sidecar 模式"; ISSUES+=("SIDECAR")
fi

S=$((S+1)); step_head $S $TOTAL "检查 DNS 配置"
MERGED_CFG="$VERGE_DATA/clash-verge.yaml"
if [[ -f "$MERGED_CFG" ]]; then
    if grep -q 'nameserver:' "$MERGED_CFG" && grep -A5 'nameserver:' "$MERGED_CFG" | grep -q '223.5.5.5'; then
        if ! grep -A5 'nameserver:' "$MERGED_CFG" | grep -qE 'wrecking|carrousel|simmering'; then
            step_warn "DNS 被覆盖为国内 DNS → 代理服务器可能解析错误"; ISSUES+=("DNS_OVERRIDE")
        fi
    else
        step_ok "DNS 使用机场原配置"
    fi
fi

S=$((S+1)); step_head $S $TOTAL "检查系统代理"
PROXY_HTTP=$(networksetup -getwebproxy Wi-Fi 2>/dev/null | grep "Enabled: Yes" || true)
PROXY_SOCKS=$(networksetup -getsocksfirewallproxy Wi-Fi 2>/dev/null | grep "Enabled: Yes" || true)
if [[ -n "$PROXY_HTTP" || -n "$PROXY_SOCKS" ]]; then
    step_warn "系统代理已开启 → TUN 模式下应关闭"; ISSUES+=("SYSPROXY")
else
    step_ok "系统代理已关闭"
fi

S=$((S+1)); step_head $S $TOTAL "检查 IPv6"
IPV6_STATUS=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep "IPv6:" | awk '{print $2}' || true)
if [[ "$IPV6_STATUS" == "Automatic" ]]; then
    step_warn "WiFi IPv6: Automatic → 建议关闭"; ISSUES+=("IPV6")
else
    step_ok "WiFi IPv6: $IPV6_STATUS"
fi

S=$((S+1)); step_head $S $TOTAL "检测出口 IP"
GEO=$(curl -s --max-time 15 https://ipinfo.io/json 2>/dev/null || true)
if [[ -n "$GEO" ]]; then
    IP=$(echo "$GEO" | grep -oP '"ip":\s*"\K[^"]+' || true)
    CITY=$(echo "$GEO" | grep -oP '"city":\s*"\K[^"]+' || true)
    COUNTRY=$(echo "$GEO" | grep -oP '"country":\s*"\K[^"]+' || true)
    ORG=$(echo "$GEO" | grep -oP '"org":\s*"\K[^"]+' || true)
    step_info "IP: $IP  地区: $CITY, $COUNTRY  机构: $ORG"
    [[ "$COUNTRY" == "US" ]] && step_ok "出口在美国" || step_warn "出口在 $COUNTRY"
else
    step_warn "无法检测出口 IP"
fi

echo ""
echo "──── 诊断汇总 ────"
if [[ ${#ISSUES[@]} -eq 0 ]]; then
    step_ok "未发现可修复的问题"
else
    step_bad "发现 ${#ISSUES[@]} 个问题: ${ISSUES[*]}"
fi

if [[ "$DIAGNOSE_ONLY" == true ]]; then
    echo "提示: 不加 --diagnose 参数可执行自动修复"
    exit 0
fi

# ══════════════════════════════════════════════════════════
#  阶段二：修复
# ══════════════════════════════════════════════════════════

S=$((S+1)); step_head $S $TOTAL "停止 Clash 所有组件"
[[ -n "$CLASH_UI" ]] && kill -9 $CLASH_UI 2>/dev/null || true
[[ -n "$MIHOMO" ]]   && kill -9 $MIHOMO 2>/dev/null || true
killall -9 "clash-verge-service" 2>/dev/null || true
killall -9 "Clash Verge" 2>/dev/null || true
killall -9 "verge-mihomo" 2>/dev/null || true
sleep 2
REMAINING=$(pgrep -f "clash-verge\|verge-mihomo" 2>/dev/null || true)
[[ -z "$REMAINING" ]] && step_ok "所有进程已停止" || step_warn "部分进程残留: $REMAINING"

S=$((S+1)); step_head $S $TOTAL "修复 verge.yaml"
if [[ -f "$VERGE_YAML" ]]; then
    sed -i.bak 's/prefer_sidecar: true/prefer_sidecar: false/g' "$VERGE_YAML"
    sed -i.bak 's/enable_dns_settings: true/enable_dns_settings: false/g' "$VERGE_YAML"
    sed -i.bak 's/last_error:.*/last_error: null/g' "$VERGE_YAML"
    rm -f "$VERGE_YAML.bak"
    step_ok "prefer_sidecar=false, enable_dns_settings=false"
fi

S=$((S+1)); step_head $S $TOTAL "优化 TUN 配置 (config.yaml)"
if [[ -f "$CONFIG_YAML" ]]; then
    sed -i.bak "s/stack: gvisor/stack: mixed/g;s/stack: system/stack: mixed/g" "$CONFIG_YAML"
    sed -i.bak "s/mtu: 1500/mtu: 9000/g" "$CONFIG_YAML"
    rm -f "$CONFIG_YAML.bak"
    step_ok "config.yaml: stack=mixed, mtu=9000"
fi

S=$((S+1)); step_head $S $TOTAL "优化 Merge Profile (不覆盖 DNS)"
PROFILES_YAML="$VERGE_DATA/profiles.yaml"
MERGE_UID=""
if [[ -f "$PROFILES_YAML" ]]; then
    MERGE_UID=$(grep -oP 'merge:\s*\K\S+' "$PROFILES_YAML" | tail -1 || true)
fi
if [[ -n "$MERGE_UID" ]]; then
    MERGE_FILE="$VERGE_DATA/profiles/$MERGE_UID.yaml"
    cat > "$MERGE_FILE" << 'MERGE_EOF'
# 性能优化 Merge Profile (不覆盖机场 DNS)
# ⚠️ 不要在此添加 dns: 段，否则会覆盖机场自带的智能 DNS 导致代理服务器解析错误

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    TLS:
      ports: [443, 8443]
    HTTP:
      ports: [80, 8080-8888]
      override-destination: true
  skip-domain:
    - "Mijia Cloud"
    - "+.apple.com"
    - "+.icloud.com"

tcp-concurrent: true
keep-alive-interval: 30
keep-alive-idle: 600

profile:
  store-selected: true
  store-fake-ip: true
MERGE_EOF
    chown "$REAL_USER" "$MERGE_FILE"
    step_ok "Merge profile: tcp-concurrent, keep-alive, sniffer (DNS 保留机场原配置)"
fi

# Cursor 分流规则
if [[ -f "$PROFILES_YAML" ]]; then
    RULES_UID=$(grep -oP 'rules:\s*\K\S+' "$PROFILES_YAML" | tail -1 || true)
    if [[ -n "$RULES_UID" ]]; then
        RULES_FILE="$VERGE_DATA/profiles/$RULES_UID.yaml"
        if [[ -f "$RULES_FILE" ]] && ! grep -q 'cursor.sh' "$RULES_FILE"; then
            cat > "$RULES_FILE" << 'RULES_EOF'
prepend:
  - DOMAIN-SUFFIX,cursor.sh,AI
  - DOMAIN-SUFFIX,cursor.com,AI
  - DOMAIN-SUFFIX,anysphere.com,AI
append: []
delete: []
RULES_EOF
            chown "$REAL_USER" "$RULES_FILE"
            step_ok "已注入 Cursor/Claude 分流规则"
        else
            step_ok "Cursor 分流规则已存在"
        fi
    fi
fi

S=$((S+1)); step_head $S $TOTAL "系统网络优化"
dscacheutil -flushcache 2>/dev/null && step_ok "DNS 缓存已刷新" || true
killall -HUP mDNSResponder 2>/dev/null || true

networksetup -setwebproxystate Wi-Fi off 2>/dev/null
networksetup -setsecurewebproxystate Wi-Fi off 2>/dev/null
networksetup -setsocksfirewallproxystate Wi-Fi off 2>/dev/null
step_ok "系统代理已关闭"

networksetup -setv6off Wi-Fi 2>/dev/null && step_ok "WiFi IPv6 已关闭" || step_warn "无法关闭 IPv6"

S=$((S+1)); step_head $S $TOTAL "启动 Clash Verge Rev"
if [[ "$SKIP_RESTART" != true && -d "$CLASH_APP" ]]; then
    sudo -u "$REAL_USER" open -a "Clash Verge" 2>/dev/null
    step_ok "Clash Verge Rev 已启动"
    step_info "等待 12 秒..."
    sleep 12
    GEO2=$(curl -s --max-time 15 https://ipinfo.io/json 2>/dev/null || true)
    if [[ -n "$GEO2" ]]; then
        IP2=$(echo "$GEO2" | grep -oP '"ip":\s*"\K[^"]+' || true)
        COUNTRY2=$(echo "$GEO2" | grep -oP '"country":\s*"\K[^"]+' || true)
        step_info "出口 IP: $IP2 ($COUNTRY2)"
    fi
fi

echo ""
echo "================================================"
echo "  修复完成!"
echo "================================================"
echo ""
echo "  已优化:"
echo "    TUN stack=mixed  MTU=9000  tcp-concurrent=true"
echo "    keep-alive=30s  sniffer=on  DNS=机场原配置"
echo "    IPv6关  系统代理关  Cursor分流规则"
echo ""
echo "  手动操作:"
echo "    1. Clash UI 中确认 TUN 模式已开启"
echo "    2. AI / Proxies / Final 选择同一个美国节点"
echo "    3. 访问 https://ipinfo.io/json 验证地区"
echo ""
