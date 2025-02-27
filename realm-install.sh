#!/bin/bash
set -euo pipefail

# 添加默认值声明
: "${file_name:=}"
: "${download_url:=}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 重置颜色

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}" >&2
        exit 1
    fi
}

# 检查必要依赖
check_dependencies() {
    local dependencies=("curl" "jq" "tar")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}错误：未找到 $cmd，请先安装${NC}" >&2
            exit 1
        fi
    done
}

# 清理临时文件
cleanup() {
    local tmp_files=("/tmp/$file_name" "/tmp/realm-"*.tar.gz)
    
    for file in "${tmp_files[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file" && echo -e "${YELLOW}已清理: $(basename "$file")${NC}" || true
        fi
    done
}

# 注册退出时清理
trap cleanup EXIT

main() {
    check_root
    check_dependencies

    # 获取系统架构
    local arch
    arch=$(uname -m)

    # 创建配置目录
    mkdir -p /etc/realm || {
        echo -e "${RED}无法创建配置目录 /etc/realm${NC}" >&2
        exit 1
    }

    # 获取最新发布版本信息
    echo -e "${YELLOW}正在获取版本信息...${NC}"
    local release_info
    release_info=$(curl -fSsL https://api.github.com/repos/zhboner/realm/releases/latest) || {
        echo -e "${RED}获取版本信息失败，请检查网络连接${NC}" >&2
        exit 1
    }

    # 提取下载信息
    local download_url file_name
    download_url=$(echo "$release_info" | jq -r --arg arch "$arch" \
        '.assets[] | select(.name | test($arch) and test("unknown-linux-gnu.tar.gz")) | .browser_download_url')
    file_name=$(echo "$release_info" | jq -r --arg arch "$arch" \
        '.assets[] | select(.name | test($arch) and test("unknown-linux-gnu.tar.gz")) | .name')

    if [ -z "$download_url" ] || [ -z "$file_name" ]; then
        echo -e "${RED}未找到与 ${arch} 架构匹配的发布文件${NC}" >&2
        exit 1
    fi

    # 显式声明这些变量为全局（因为会被 cleanup 函数使用）
    declare -g download_url file_name

    #版本号校验
    version=$(echo "$release_info" | jq -r '.tag_name')
    echo -e "正在安装 realm ${GREEN}$version${NC}"

    # 下载文件
    echo -e "${YELLOW}正在下载 $file_name ...${NC}"
    if ! curl -fL --retry 3 --retry-delay 2 -o "/tmp/$file_name" "$download_url"; then
        echo -e "${RED}文件下载失败${NC}" >&2
        exit 1
    fi

    # 验证文件完整性
    if [ ! -s "/tmp/$file_name" ]; then
        echo -e "${RED}错误：下载文件为空或不存在${NC}" >&2
        exit 1
    fi

    # 在解压前添加校验
    file_type=$(file "/tmp/$file_name")
    if ! [[ "$file_type" == *"gzip compressed data"* ]]; then
        echo -e "${RED}文件类型不匹配，可能下载损坏${NC}"
        exit 1
    fi

    # 解压文件
    echo -e "${YELLOW}正在解压文件...${NC}"
    if ! tar -xzvf "/tmp/$file_name" -C "/usr/local/bin/"; then
        echo -e "${RED}文件解压失败${NC}" >&2
        exit 1
    fi

    # 创建 systemd 服务
    echo -e "${YELLOW}正在配置系统服务...${NC}"
    cat > /etc/systemd/system/realm.service << EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
WorkingDirectory=/etc/realm
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml

[Install]
WantedBy=multi-user.target
EOF

    # 创建配置文件（如果不存在）
    if [ ! -f "/etc/realm/config.toml" ]; then
        cat > /etc/realm/config.toml << EOF
[[endpoints]]
listen = "0.0.0.0:5000"
remote = "1.1.1.1:443"

[[endpoints]]
listen = "0.0.0.0:10000"
remote = "www.google.com:443"
EOF
    else
        echo -e "${YELLOW}配置文件已存在，跳过创建${NC}"
    fi

    # 重载 systemd
    systemctl daemon-reload
    echo -e "${GREEN}安装完成！\n启动命令：systemctl start realm\n开机自启：systemctl enable realm${NC}"
}

main "$@"
