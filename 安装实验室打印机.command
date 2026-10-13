#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_REVISION="2026-07-24-r5"
PKG_NAME="insolu-PrintClient-PJ-Macos-sig-INSOLU-PDF-X86-v3.0.4.3.pkg"
PKG_PATH="${SCRIPT_DIR}/${PKG_NAME}"
EXPECTED_SHA256="1c89f605bb47b0d561f3a0cc9b6c4964bdb580ab007da5575e6baee88a5fa8a1"
EXPECTED_INSTALLER_ID="Developer ID Installer: Guangdong Xunwei Information Industry Co., Ltd (JFC8NF8AS4)"

BRIDGE_SCRIPT_SOURCE="${SCRIPT_DIR}/pjlab_https_bridge.py"
BRIDGE_AGENT_SOURCE="${SCRIPT_DIR}/org.pjlab.print-https-bridge.plist"
AUTH_CACHE_SOURCE="${SCRIPT_DIR}/OpenAuthListCache.json"
PPD_COMPAT_FRAGMENT_SOURCE="${SCRIPT_DIR}/CpmsPrinter-INOutputMode.ppd.inc"
EXPECTED_BRIDGE_SHA256="a4e7bd6b562a760bcaac871070fbed8870790753d690b6b8d201a71a14c7505e"
EXPECTED_BRIDGE_AGENT_SHA256="985ba0046ea0e98c8a91416f3c27ee3c08361c7381e75b87fe8e27d7dfefc925"
EXPECTED_AUTH_CACHE_SHA256="e9ce7c40b29e56c36b573404b2705aecf3cf58bbacd37490dd3c64645e9481b9"
EXPECTED_PPD_COMPAT_FRAGMENT_SHA256="7301c6f975f5ac60a3dac48e72d70b5ad7165facc3acce2f6b655446333db5b3"

SERVER_HOST="mprint.pjlab.org.cn"
SERVER_URL="https://${SERVER_HOST}:8085"
BRIDGE_HOST="127.0.0.1"
BRIDGE_PORT="18085"
BRIDGE_URL="http://${BRIDGE_HOST}:${BRIDGE_PORT}"
CLIENT_SERVER_URL="${BRIDGE_URL}"
BRIDGE_LABEL="org.pjlab.print-https-bridge"
BRIDGE_INSTALL_DIR="/Library/Application Support/PJLabPrintBridge"
BRIDGE_SCRIPT_INSTALLED="${BRIDGE_INSTALL_DIR}/pjlab_https_bridge.py"
BRIDGE_AGENT_INSTALLED="${HOME}/Library/LaunchAgents/${BRIDGE_LABEL}.plist"
QUEUE_NAME="L1-Printer"
DEVICE_URI="CpmsPrinterINSOLU:/"

CONFIGURE_INI="/Library/insolu/client001/configure.ini"
AUTH_CACHE_INSTALLED="/Library/insolu/client001/OpenAuthListCache.json"
DRIVER_INI="/Library/insolu/client001/DriverClient.ini"
APP_PATH="/Library/insolu/client001/PrintClient.app"
APP_LINK="/Applications/智能打印.app"
BACKEND_SOURCE="/Library/Printers/insolu/CPMSPrinter/CpmsPrinter"
BACKEND_LINK="/usr/libexec/cups/backend/CpmsPrinterINSOLU"
PPD_PATH="/Library/Printers/PPDs/Contents/Resources/HP_INSOLU_PDF_GRAY_DUPLEX.gz"
COMPAT_PPD_PATH="/Library/Printers/PPDs/Contents/Resources/PJLAB_INSOLU_PDF_GRAY_DUPLEX.ppd"
ACTIVE_PPD_PATH="/etc/cups/ppd/${QUEUE_NAME}.ppd"
DAEMON_PLIST="/Library/LaunchDaemons/com.insolu.CpmsDeamon.plist"
DAEMON_LABEL="com.insolu.CpmsDeamon.plist"

CHECK_ONLY=0
PRINT_REPAIR_ONLY=0
QUEUE_REMAINS_PAUSED=0
OLD_DEFAULT=""
DEFAULT_RESTORED=0
ADMIN_GRANTED=0
if [[ "${1:-}" == "--check-only" ]]; then
    CHECK_ONLY=1
elif [[ "${1:-}" == "--repair-print" ]]; then
    PRINT_REPAIR_ONLY=1
elif [[ $# -gt 0 ]]; then
    echo "用法：$0 [--check-only|--repair-print]" >&2
    exit 2
fi

info() {
    printf "\n==> %s\n" "$1"
}

ok() {
    printf "    [通过] %s\n" "$1"
}

warn() {
    printf "    [提醒] %s\n" "$1" >&2
}

fail() {
    printf "\n[失败] %s\n" "$1" >&2
    printf "终端窗口会保留，便于查看上面的错误信息。\n" >&2
    exit 1
}

pause_before_exit() {
    if [[ -t 0 ]]; then
        printf "\n按回车键关闭此窗口..."
        read -r _
    fi
}

current_default_printer() {
    /usr/bin/lpstat -d 2>/dev/null \
        | /usr/bin/sed -E 's/^.*[:：][[:space:]]*//' \
        | /usr/bin/head -n 1
}

restore_default_printer() {
    if [[ "${DEFAULT_RESTORED}" -ne 0 ]]; then
        return 0
    fi
    DEFAULT_RESTORED=1

    if [[ -z "${OLD_DEFAULT}" ]] \
        || [[ "${OLD_DEFAULT}" == "${QUEUE_NAME}" ]] \
        || ! /usr/bin/lpstat -p "${OLD_DEFAULT}" >/dev/null 2>&1; then
        return 0
    fi

    /usr/bin/lpoptions -d "${OLD_DEFAULT}" >/dev/null 2>&1 || true
    if [[ "${ADMIN_GRANTED}" -eq 1 ]] \
        && /usr/bin/sudo -n /usr/bin/true >/dev/null 2>&1; then
        /usr/bin/sudo -n /usr/sbin/lpadmin -d "${OLD_DEFAULT}" >/dev/null 2>&1 || true
    fi
    ok "已保留原来的默认打印机：${OLD_DEFAULT}"
    return 0
}

on_exit() {
    local status=$?
    trap - EXIT
    restore_default_printer || true
    pause_before_exit
    exit "${status}"
}

verify_pkg() {
    [[ -f "${PKG_PATH}" ]] || fail "找不到原厂安装包：${PKG_PATH}"

    local actual_sha
    actual_sha="$(/usr/bin/shasum -a 256 "${PKG_PATH}" | /usr/bin/awk '{print $1}')"
    [[ "${actual_sha}" == "${EXPECTED_SHA256}" ]] \
        || fail "安装包 SHA-256 不匹配，文件可能损坏或被替换。"
    ok "安装包 SHA-256 完整"

    local signature_output
    signature_output="$(/usr/sbin/pkgutil --check-signature "${PKG_PATH}" 2>&1)" \
        || fail "macOS 无法验证安装包签名。"
    /usr/bin/grep -Fq "${EXPECTED_INSTALLER_ID}" <<<"${signature_output}" \
        || fail "安装包签名者不是预期的广东迅维 Developer ID。"
    /usr/bin/grep -Fq "Notarization: trusted by the Apple notary service" <<<"${signature_output}" \
        || fail "安装包未通过 Apple 公证验证。"
    /usr/sbin/spctl --assess --type install "${PKG_PATH}" >/dev/null 2>&1 \
        || fail "Gatekeeper 拒绝了这个安装包。"
    ok "Developer ID 签名和 Apple 公证有效"

    [[ -f "${BRIDGE_SCRIPT_SOURCE}" ]] \
        || fail "找不到本机 HTTPS 桥脚本：${BRIDGE_SCRIPT_SOURCE}"
    [[ -f "${BRIDGE_AGENT_SOURCE}" ]] \
        || fail "找不到本机 HTTPS 桥启动配置：${BRIDGE_AGENT_SOURCE}"
    [[ -f "${AUTH_CACHE_SOURCE}" ]] \
        || fail "找不到 AD 域认证列表配置：${AUTH_CACHE_SOURCE}"
    [[ -f "${PPD_COMPAT_FRAGMENT_SOURCE}" ]] \
        || fail "找不到原厂 backend 兼容补丁：${PPD_COMPAT_FRAGMENT_SOURCE}"

    local bridge_sha bridge_agent_sha auth_cache_sha ppd_compat_fragment_sha
    bridge_sha="$(/usr/bin/shasum -a 256 "${BRIDGE_SCRIPT_SOURCE}" | /usr/bin/awk '{print $1}')"
    bridge_agent_sha="$(/usr/bin/shasum -a 256 "${BRIDGE_AGENT_SOURCE}" | /usr/bin/awk '{print $1}')"
    auth_cache_sha="$(/usr/bin/shasum -a 256 "${AUTH_CACHE_SOURCE}" | /usr/bin/awk '{print $1}')"
    ppd_compat_fragment_sha="$(/usr/bin/shasum -a 256 "${PPD_COMPAT_FRAGMENT_SOURCE}" | /usr/bin/awk '{print $1}')"
    [[ "${bridge_sha}" == "${EXPECTED_BRIDGE_SHA256}" ]] \
        || fail "HTTPS 桥脚本 SHA-256 不匹配，文件可能损坏或被替换。"
    [[ "${bridge_agent_sha}" == "${EXPECTED_BRIDGE_AGENT_SHA256}" ]] \
        || fail "HTTPS 桥启动配置 SHA-256 不匹配，文件可能损坏或被替换。"
    [[ "${auth_cache_sha}" == "${EXPECTED_AUTH_CACHE_SHA256}" ]] \
        || fail "AD 域认证列表配置 SHA-256 不匹配，文件可能损坏或被替换。"
    [[ "${ppd_compat_fragment_sha}" == "${EXPECTED_PPD_COMPAT_FRAGMENT_SHA256}" ]] \
        || fail "原厂 backend 兼容补丁 SHA-256 不匹配，文件可能损坏或被替换。"
    /usr/bin/plutil -lint "${BRIDGE_AGENT_SOURCE}" >/dev/null \
        || fail "HTTPS 桥启动配置格式无效。"
    [[ -x /usr/bin/python3 ]] \
        || fail "系统缺少 /usr/bin/python3，无法验证 AD 域认证列表配置。"
    /usr/bin/python3 -c \
        'import json, pathlib, sys; json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
        "${AUTH_CACHE_SOURCE}" \
        || fail "AD 域认证列表配置不是有效 JSON。"
    /usr/bin/grep -Fqx '*DefaultINOutputMode: Color' "${PPD_COMPAT_FRAGMENT_SOURCE}" \
        || fail "原厂 backend 兼容补丁缺少默认彩色属性。"
    /usr/bin/grep -Fqx '*INOutputMode Color/Color: ""' "${PPD_COMPAT_FRAGMENT_SOURCE}" \
        || fail "原厂 backend 兼容补丁缺少彩色属性。"
    ok "辅助 HTTPS 桥、AD 域认证与打印 backend 兼容补丁完整"
}

check_network() {
    if ! /usr/bin/dscacheutil -q host -a name "${SERVER_HOST}" \
        | /usr/bin/grep -q "ip_address"; then
        fail "无法解析 ${SERVER_HOST}。请先连接实验室网络或 VPN。"
    fi

    if ! /usr/bin/curl --noproxy '*' --fail --silent --show-error --output /dev/null \
        --connect-timeout 5 --max-time 12 \
        "${SERVER_URL}/cpms/api/childNode/sysEdition"; then
        fail "无法连接 ${SERVER_URL}。请先连接实验室网络或 VPN。"
    fi
    ok "实验室打印服务器可连接"
}

check_rosetta() {
    if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
        ok "当前是 Intel Mac，无需 Rosetta"
        return
    fi

    if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
        ok "Rosetta 可用"
        return
    fi

    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        warn "未安装 Rosetta；正式安装时会自动安装。"
        return
    fi

    info "安装 Apple Rosetta（原厂客户端是 Intel 版本）"
    /usr/bin/sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license \
        || fail "Rosetta 安装失败。"
    /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1 \
        || fail "Rosetta 安装后仍不可用。"
    ok "Rosetta 安装完成"
}

check_bridge_runtime() {
    [[ -x /usr/bin/python3 ]] \
        || fail "系统缺少 /usr/bin/python3，无法运行原厂旧版客户端所需的 HTTPS 兼容桥。"
    /usr/bin/python3 -c \
        'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
        "${BRIDGE_SCRIPT_SOURCE}" \
        || fail "HTTPS 桥脚本语法检查失败。"
    /usr/bin/python3 -c 'import http.client, http.server, ssl' \
        || fail "系统 Python 缺少 HTTPS 桥所需的标准库。"
    ok "本机 HTTPS 兼容桥运行环境可用"
}

root_owned_path_is_cups_safe() {
    local path="$1"
    local kind="$2"
    local stat_fields owner mode mode_value

    [[ "${kind}" == "directory" && -d "${path}" ]] \
        || [[ "${kind}" == "file" && -f "${path}" ]] \
        || return 1
    stat_fields="$(/usr/bin/stat -f '%u %Lp' "${path}")" || return 1
    owner="${stat_fields%% *}"
    mode="${stat_fields##* }"
    [[ "${owner}" == "0" ]] || return 1
    mode_value=$((8#${mode}))
    (( (mode_value & 8#022) == 0 ))
}

queue_uses_compat_ppd() {
    [[ -f "${ACTIVE_PPD_PATH}" ]] \
        && /usr/bin/grep -Eq '^\*DefaultINOutputMode: (Grayscale|Color)$' "${ACTIVE_PPD_PATH}" \
        && /usr/bin/grep -Fqx '*INOutputMode Color/Color: ""' "${ACTIVE_PPD_PATH}"
}

show_installed_status() {
    if [[ -d "${APP_PATH}" ]]; then
        ok "客户端已存在：${APP_LINK}"
    else
        warn "客户端尚未安装"
    fi

    if /usr/bin/lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1; then
        if /usr/bin/lpoptions -p "${QUEUE_NAME}" 2>/dev/null \
            | /usr/bin/grep -Fq "device-uri=${DEVICE_URI}"; then
            ok "打印队列和 backend URI 正确：${QUEUE_NAME}"
        else
            warn "打印队列存在，但 backend URI 不正确"
        fi
        /usr/bin/lpstat -p "${QUEUE_NAME}" -v 2>/dev/null || true
    else
        warn "打印队列尚未建立：${QUEUE_NAME}"
    fi

    if [[ -L "${BACKEND_LINK}" ]] \
        && [[ "$(/usr/bin/readlink "${BACKEND_LINK}")" == "${BACKEND_SOURCE}" ]] \
        && root_owned_path_is_cups_safe "/Library/Printers/insolu" directory \
        && root_owned_path_is_cups_safe "/Library/Printers/insolu/CPMSPrinter" directory \
        && root_owned_path_is_cups_safe "${BACKEND_SOURCE}" file; then
        ok "CUPS backend 路径及安全权限正确"
    else
        warn "CUPS backend 不存在、链接错误或路径权限不符合 CUPS 安全要求"
    fi

    if queue_uses_compat_ppd; then
        ok "兼容 PPD 已包含 INOutputMode，已避开原厂空指针崩溃"
    elif [[ -f "${ACTIVE_PPD_PATH}" ]]; then
        warn "当前 PPD 缺少 INOutputMode；原厂 backend 会在解析颜色属性时崩溃"
    else
        warn "当前队列缺少活动 PPD"
    fi

    if [[ -f "${CONFIGURE_INI}" ]] \
        && /usr/bin/grep -Fqx "ServerAddr=${CLIENT_SERVER_URL}" "${CONFIGURE_INI}"; then
        ok "客户端链路正确：本机 HTTPS 桥 → ${SERVER_URL}"
    elif [[ -f "${CONFIGURE_INI}" ]]; then
        warn "客户端存在，但尚未指向本机 HTTPS 兼容桥"
    fi
    if [[ -f "${CONFIGURE_INI}" ]] \
        && [[ -f "${AUTH_CACHE_INSTALLED}" ]] \
        && /usr/bin/grep -Fqx "forceAdAutoLoginEnable=0" "${CONFIGURE_INI}" \
        && /usr/bin/grep -Fqx "loginType=1" "${CONFIGURE_INI}" \
        && /usr/bin/grep -Fq '"code\":\"sys_identify_AD\"' "${AUTH_CACHE_INSTALLED}"; then
        ok "认证方式列表已恢复并选中 AD 域认证"
    elif [[ -f "${CONFIGURE_INI}" ]]; then
        warn "客户端尚未固定为实验室要求的 AD 域认证"
    fi

    local user_domain
    user_domain="gui/$(/usr/bin/id -u)/${BRIDGE_LABEL}"
    if /bin/launchctl print "${user_domain}" >/dev/null 2>&1 \
        && /usr/bin/curl --noproxy '*' --fail --silent --output /dev/null \
            --connect-timeout 2 --max-time 5 \
            "${BRIDGE_URL}/__pjlab_bridge_health__"; then
        ok "本机 HTTPS 兼容桥正在运行"
    else
        warn "本机 HTTPS 兼容桥尚未运行"
    fi
}

repair_https_bridge() {
    /usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 \
        "${BRIDGE_INSTALL_DIR}"
    /usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 \
        "${BRIDGE_SCRIPT_SOURCE}" "${BRIDGE_SCRIPT_INSTALLED}"

    /usr/bin/install -d -m 0755 "${HOME}/Library/LaunchAgents"
    /usr/bin/install -m 0644 "${BRIDGE_AGENT_SOURCE}" "${BRIDGE_AGENT_INSTALLED}"

    local installed_sha
    installed_sha="$(/usr/bin/shasum -a 256 "${BRIDGE_SCRIPT_INSTALLED}" | /usr/bin/awk '{print $1}')"
    [[ "${installed_sha}" == "${EXPECTED_BRIDGE_SHA256}" ]] \
        || fail "安装后的 HTTPS 桥文件校验失败。"
    /usr/bin/plutil -lint "${BRIDGE_AGENT_INSTALLED}" >/dev/null \
        || fail "安装后的 HTTPS 桥启动配置无效。"

    local user_domain user_service
    user_domain="gui/$(/usr/bin/id -u)"
    user_service="${user_domain}/${BRIDGE_LABEL}"
    /bin/launchctl bootout "${user_service}" >/dev/null 2>&1 || true
    /bin/launchctl bootout "${user_domain}" "${BRIDGE_AGENT_INSTALLED}" \
        >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "${user_domain}" "${BRIDGE_AGENT_INSTALLED}" \
        || fail "无法加载本机 HTTPS 兼容桥。"
    /bin/launchctl enable "${user_service}" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "${user_service}" >/dev/null 2>&1 || true

    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if /usr/bin/curl --noproxy '*' --fail --silent --output /dev/null \
            --connect-timeout 2 --max-time 4 \
            "${BRIDGE_URL}/__pjlab_bridge_health__"; then
            break
        fi
        /bin/sleep 1
    done

    /usr/bin/curl --noproxy '*' --fail --silent --output /dev/null \
        --connect-timeout 2 --max-time 5 \
        "${BRIDGE_URL}/__pjlab_bridge_health__" \
        || fail "本机 HTTPS 兼容桥未能启动。"
    /usr/bin/curl --noproxy '*' --fail --silent --output /dev/null \
        --connect-timeout 5 --max-time 15 \
        "${BRIDGE_URL}/cpms/api/childNode/sysEdition" \
        || fail "本机 HTTPS 兼容桥无法访问实验室打印服务器。"
    ok "本机 HTTPS 兼容桥已启动并通过联网验证"
}

repair_configuration() {
    [[ -f "${CONFIGURE_INI}" ]] || fail "安装后缺少 ${CONFIGURE_INI}"
    [[ -f "${DRIVER_INI}" ]] || fail "安装后缺少 ${DRIVER_INI}"

    /usr/bin/sudo /usr/bin/sed -i '' -E \
        "s|^ServerAddr=.*$|ServerAddr=${CLIENT_SERVER_URL}|" "${CONFIGURE_INI}"
    /usr/bin/sudo /usr/bin/sed -i '' -E \
        "s|^CenterServerAddr=.*$|CenterServerAddr=${CLIENT_SERVER_URL}|" "${CONFIGURE_INI}"
    # 原厂 macOS 客户端会拒绝为 127.0.0.1 加载认证方式列表。
    # 缓存唯一的 AD 项，并关闭域内 Windows 专用的自动 AD 登录流程，
    # 让 macOS 显示真正的 AD 密码登录页。枚举 1=AD，0=本地 CPMS 账号。
    /usr/bin/sudo /usr/bin/sed -i '' -E \
        's|^forceAdAutoLoginEnable=.*$|forceAdAutoLoginEnable=0|' "${CONFIGURE_INI}"
    /usr/bin/sudo /usr/bin/sed -i '' -E \
        's|^loginType=.*$|loginType=1|' "${CONFIGURE_INI}"
    /usr/bin/sudo /usr/bin/install \
        -o "$(/usr/bin/id -un)" \
        -g "$(/usr/bin/id -gn)" \
        -m 0644 \
        "${AUTH_CACHE_SOURCE}" "${AUTH_CACHE_INSTALLED}"
    /usr/bin/sudo /usr/bin/sed -i '' -E \
        's|^Mode=.*$|Mode=0|' "${DRIVER_INI}"

    /usr/bin/grep -Fqx "ServerAddr=${CLIENT_SERVER_URL}" "${CONFIGURE_INI}" \
        || fail "ServerAddr 写入失败。"
    /usr/bin/grep -Fqx "CenterServerAddr=${CLIENT_SERVER_URL}" "${CONFIGURE_INI}" \
        || fail "CenterServerAddr 写入失败。"
    /usr/bin/grep -Fqx "forceAdAutoLoginEnable=0" "${CONFIGURE_INI}" \
        || fail "AD 域认证开关写入失败。"
    /usr/bin/grep -Fqx "loginType=1" "${CONFIGURE_INI}" \
        || fail "AD 域认证类型写入失败。"
    local installed_auth_cache_sha
    installed_auth_cache_sha="$(/usr/bin/shasum -a 256 "${AUTH_CACHE_INSTALLED}" | /usr/bin/awk '{print $1}')"
    [[ "${installed_auth_cache_sha}" == "${EXPECTED_AUTH_CACHE_SHA256}" ]] \
        || fail "AD 域认证列表配置安装校验失败。"
    /usr/bin/grep -Fqx "Mode=0" "${DRIVER_INI}" \
        || fail "HTTPS 模式写入失败。"
    ok "客户端已恢复 AD 域认证页面，并经本机回环桥安全连接 ${SERVER_URL}"
}

build_and_install_compat_ppd() {
    [[ -f "${PPD_PATH}" ]] || fail "安装后缺少原厂 PPD：${PPD_PATH}"
    /usr/bin/gzip -t "${PPD_PATH}" \
        || fail "原厂 PPD 压缩文件已损坏：${PPD_PATH}"

    local temp_dir vendor_ppd compat_ppd
    temp_dir="$(/usr/bin/mktemp -d /tmp/pjlab-print-ppd.XXXXXX)" \
        || fail "无法创建 PPD 临时目录。"
    vendor_ppd="${temp_dir}/vendor.ppd"
    compat_ppd="${temp_dir}/pjlab-compat.ppd"

    if ! /usr/bin/gzip -dc "${PPD_PATH}" >"${vendor_ppd}"; then
        /bin/rm -f "${vendor_ppd}" "${compat_ppd}"
        /bin/rmdir "${temp_dir}" >/dev/null 2>&1 || true
        fail "无法读取原厂 PPD。"
    fi

    if /usr/bin/grep -Eq '^\*OpenUI[[:space:]]+\*INOutputMode/' "${vendor_ppd}"; then
        /usr/bin/install -m 0600 "${vendor_ppd}" "${compat_ppd}" \
            || fail "无法准备兼容 PPD。"
    else
        if ! /usr/bin/awk -v patch_file="${PPD_COMPAT_FRAGMENT_SOURCE}" '
            /^\*LandscapeOrientation:/ && !inserted {
                while ((getline patch_line < patch_file) > 0) {
                    print patch_line
                }
                close(patch_file)
                print ""
                inserted = 1
            }
            { print }
            END {
                if (!inserted) {
                    exit 42
                }
            }
        ' "${vendor_ppd}" >"${compat_ppd}"; then
            /bin/rm -f "${vendor_ppd}" "${compat_ppd}"
            /bin/rmdir "${temp_dir}" >/dev/null 2>&1 || true
            fail "无法把 INOutputMode 兼容字段写入原厂 PPD。"
        fi
    fi

    if ! /usr/bin/grep -Fqx '*DefaultINOutputMode: Color' "${compat_ppd}" \
        || ! /usr/bin/grep -Fqx '*INOutputMode Color/Color: ""' "${compat_ppd}" \
        || ! /usr/bin/cupstestppd -q -W all "${compat_ppd}"; then
        /bin/rm -f "${vendor_ppd}" "${compat_ppd}"
        /bin/rmdir "${temp_dir}" >/dev/null 2>&1 || true
        fail "生成的兼容 PPD 未通过 CUPS 校验。"
    fi

    /usr/bin/sudo /usr/bin/install -o root -g wheel -m 0644 \
        "${compat_ppd}" "${COMPAT_PPD_PATH}" \
        || fail "无法安装兼容 PPD。"
    /bin/rm -f "${vendor_ppd}" "${compat_ppd}"
    /bin/rmdir "${temp_dir}" >/dev/null 2>&1 || true
    ok "已补全原厂 Mac PPD 遗漏的 INOutputMode"
}

secure_backend_path() {
    local path

    [[ -f "${BACKEND_SOURCE}" ]] || fail "安装后缺少 CUPS backend：${BACKEND_SOURCE}"

    for path in \
        "/Library/Printers/insolu" \
        "/Library/Printers/insolu/CPMSPrinter"; do
        [[ -d "${path}" ]] || fail "安装后缺少 CUPS backend 目录：${path}"
        /usr/bin/sudo /usr/sbin/chown root:wheel "${path}"
        /usr/bin/sudo /bin/chmod 0755 "${path}"
    done

    if [[ -d "/Library/Printers/insolu/Filter" ]]; then
        /usr/bin/sudo /usr/sbin/chown root:wheel "/Library/Printers/insolu/Filter"
        /usr/bin/sudo /bin/chmod 0755 "/Library/Printers/insolu/Filter"
    fi

    for path in \
        "${BACKEND_SOURCE}" \
        "/Library/Printers/insolu/CPMSPrinter/CpmsPrinterINSOLU" \
        "/Library/Printers/insolu/CPMSPrinter/var.sh"; do
        if [[ -f "${path}" ]]; then
            /usr/bin/sudo /usr/sbin/chown root:wheel "${path}"
            /usr/bin/sudo /bin/chmod 0700 "${path}"
        fi
    done

    if [[ -f "/Library/Printers/insolu/CPMSPrinter/cpms-printer-deamon" ]]; then
        /usr/bin/sudo /usr/sbin/chown root:wheel \
            "/Library/Printers/insolu/CPMSPrinter/cpms-printer-deamon"
        /usr/bin/sudo /bin/chmod 0755 \
            "/Library/Printers/insolu/CPMSPrinter/cpms-printer-deamon"
    fi

    /usr/bin/sudo /bin/test -x "${BACKEND_SOURCE}" \
        || fail "CUPS backend 已存在，但 root 无法执行：${BACKEND_SOURCE}"
    root_owned_path_is_cups_safe "/Library/Printers/insolu" directory \
        || fail "CUPS backend 上级目录权限仍不安全。"
    root_owned_path_is_cups_safe "/Library/Printers/insolu/CPMSPrinter" directory \
        || fail "CUPS backend 所在目录权限仍不安全。"
    root_owned_path_is_cups_safe "${BACKEND_SOURCE}" file \
        || fail "CUPS backend 文件权限仍不安全。"

    /usr/bin/sudo /bin/ln -sfn "${BACKEND_SOURCE}" "${BACKEND_LINK}"
    [[ -L "${BACKEND_LINK}" ]] \
        && [[ "$(/usr/bin/readlink "${BACKEND_LINK}")" == "${BACKEND_SOURCE}" ]] \
        || fail "CUPS backend 链接校验失败。"
    ok "CUPS backend 路径权限和链接符合安全要求"
}

repair_print_queue() {
    local queue_existed=0
    local queue_was_stopped=0
    local pending_jobs=0
    local queue_options=""
    local pending_job_list=""

    if /usr/bin/lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1; then
        queue_existed=1
        if ! queue_options="$(/usr/bin/lpoptions -p "${QUEUE_NAME}" 2>/dev/null)"; then
            queue_was_stopped=1
            warn "无法可靠读取原队列状态；为安全起见，修复后将保持暂停。"
        elif /usr/bin/grep -Eq '(^|[[:space:]])printer-state=5([[:space:]]|$)' \
            <<<"${queue_options}"; then
            queue_was_stopped=1
        fi

        if ! pending_job_list="$(/usr/bin/lpstat -W not-completed -o "${QUEUE_NAME}" 2>/dev/null)"; then
            queue_was_stopped=1
            warn "无法可靠读取旧任务列表；为安全起见，修复后将保持暂停。"
        else
            pending_jobs="$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' \
                <<<"${pending_job_list}")"
            if [[ "${pending_jobs}" -gt 0 ]]; then
                queue_was_stopped=1
            fi
        fi
    fi

    if [[ "${queue_existed}" -eq 1 && "${queue_was_stopped}" -eq 1 ]]; then
        /usr/bin/sudo /usr/sbin/cupsdisable \
            -r "正在安装兼容修复，旧任务保持暂停" "${QUEUE_NAME}" \
            || fail "无法在修复前安全暂停 ${QUEUE_NAME}。"
    fi

    secure_backend_path
    build_and_install_compat_ppd

    /usr/bin/sudo /usr/sbin/lpadmin \
        -p "${QUEUE_NAME}" \
        -v "${DEVICE_URI}" \
        -P "${COMPAT_PPD_PATH}" \
        -o printer-is-shared=false \
        -o ColorModel=RGB \
        -o INOutputMode=Color \
        || fail "无法更新 ${QUEUE_NAME} 打印队列。"
    /usr/bin/sudo /usr/sbin/cupsaccept "${QUEUE_NAME}"

    if [[ "${queue_existed}" -eq 1 && "${queue_was_stopped}" -eq 1 ]]; then
        /usr/bin/sudo /usr/sbin/cupsdisable \
            -r "兼容修复已完成，等待用户确认旧任务" "${QUEUE_NAME}"
        QUEUE_REMAINS_PAUSED=1
    else
        /usr/bin/sudo /usr/sbin/cupsenable "${QUEUE_NAME}"
    fi

    /usr/bin/lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1 \
        || fail "${QUEUE_NAME} 打印队列验证失败。"
    /usr/bin/lpoptions -p "${QUEUE_NAME}" 2>/dev/null \
        | /usr/bin/grep -Fq "device-uri=${DEVICE_URI}" \
        || fail "${QUEUE_NAME} backend URI 验证失败。"
    queue_uses_compat_ppd \
        || fail "${QUEUE_NAME} 尚未使用包含 INOutputMode 的兼容 PPD。"
    /usr/bin/lpoptions -p "${QUEUE_NAME}" -l 2>/dev/null \
        | /usr/bin/grep -Eq '^INOutputMode/' \
        || fail "CUPS 未加载兼容 PPD 的 INOutputMode。"

    if [[ "${QUEUE_REMAINS_PAUSED}" -eq 1 ]]; then
        ok "打印链路已修复；队列按原状态保持暂停"
        if [[ "${pending_jobs}" -gt 0 ]]; then
            warn "检测到 ${pending_jobs} 个旧任务；尚未恢复，避免突然打印或重复计费。"
        fi
    else
        ok "CUPS 打印队列可用：${QUEUE_NAME}"
    fi
}

repair_daemon() {
    [[ -f "${DAEMON_PLIST}" ]] || fail "安装后缺少后台服务配置：${DAEMON_PLIST}"

    if ! /usr/bin/sudo /bin/launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
        /usr/bin/sudo /bin/launchctl bootout system "${DAEMON_PLIST}" >/dev/null 2>&1 || true
        /usr/bin/sudo /bin/launchctl bootstrap system "${DAEMON_PLIST}" \
            || fail "无法启动打印后台服务。"
    fi
    /usr/bin/sudo /bin/launchctl enable "system/${DAEMON_LABEL}" >/dev/null 2>&1 || true
    /usr/bin/sudo /bin/launchctl kickstart -k "system/${DAEMON_LABEL}" >/dev/null 2>&1 || true
    ok "打印后台服务已加载"
}

main() {
    trap on_exit EXIT

    info "检查系统与原厂安装包（${INSTALLER_REVISION}）"
    [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "此安装器只能在 macOS 上运行。"
    [[ "$(/usr/bin/id -u)" -ne 0 ]] \
        || fail "请直接以当前登录用户运行此脚本，不要在命令前添加 sudo。"
    verify_pkg

    if [[ "${PRINT_REPAIR_ONLY}" -eq 1 ]]; then
        OLD_DEFAULT="$(current_default_printer)"
        info "请求管理员权限，仅修复 CUPS backend 和兼容 PPD"
        printf "请输入这台 Mac 的登录密码；输入时终端不会显示字符，这是正常现象。\n"
        /usr/bin/sudo -v || fail "未获得管理员权限。"
        ADMIN_GRANTED=1
        check_rosetta
        repair_print_queue
        restore_default_printer

        info "打印 backend 修复完成"
        if [[ "${QUEUE_REMAINS_PAUSED}" -eq 1 ]]; then
            printf "现有队列仍保持暂停，因此旧文档不会突然打印。\n"
            printf "请回到 Codex，确认是取消旧任务还是恢复它，再进行一页测试。\n"
        else
            printf "队列中没有需要保护的暂停状态，可以提交一页无敏感内容的测试文档。\n"
        fi
        return
    fi

    check_network
    check_rosetta
    check_bridge_runtime

    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        info "当前安装状态"
        show_installed_status
        printf "\n检查完成；没有修改系统。\n"
        return
    fi

    OLD_DEFAULT="$(current_default_printer)"

    info "请求管理员权限"
    printf "请输入这台 Mac 的登录密码；输入时终端不会显示字符，这是正常现象。\n"
    /usr/bin/sudo -v || fail "未获得管理员权限。"
    ADMIN_GRANTED=1

    if [[ -d "${APP_PATH}" ]] \
        && [[ -f "${CONFIGURE_INI}" ]] \
        && [[ -f "${DRIVER_INI}" ]] \
        && [[ -f "${BACKEND_SOURCE}" ]] \
        && [[ -f "${PPD_PATH}" ]] \
        && [[ -f "${DAEMON_PLIST}" ]]; then
        info "检测到原厂客户端已完整落盘"
        ok "跳过重复安装，继续修复剩余配置"
    else
        info "安装广东迅维原厂 macOS 客户端"
        /usr/bin/sudo /usr/sbin/installer -pkg "${PKG_PATH}" -target / \
            || fail "原厂安装包安装失败。"
        ok "原厂客户端安装完成"
    fi

    info "建立 HTTPS 兼容桥并修复打印链路"
    /usr/bin/sudo /usr/bin/pkill -x PrintClient >/dev/null 2>&1 || true
    repair_https_bridge
    repair_configuration
    repair_print_queue
    repair_daemon

    restore_default_printer

    [[ -d "${APP_PATH}" ]] || fail "找不到安装后的智能打印应用。"
    /usr/bin/open -n "${APP_PATH}"

    info "安装完成"
    printf "1. 确认第一栏显示“AD域认证”，再填写实验室 AD 账号和密码。\n"
    printf "2. 打印时选择打印机“%s”。\n" "${QUEUE_NAME}"
    if [[ "${QUEUE_REMAINS_PAUSED}" -eq 1 ]]; then
        printf "3. 队列因已有旧任务而保持暂停；先确认旧任务后再恢复。\n"
    else
        printf "3. 任务提交后，到打印机旁刷卡，再在屏幕上释放任务。\n"
    fi
    printf "4. 此脚本没有自动打印测试页，避免浪费纸张。\n"
    printf "5. 本机 HTTPS 兼容桥仅监听 127.0.0.1，不会对局域网开放端口。\n"
}

main "$@"
