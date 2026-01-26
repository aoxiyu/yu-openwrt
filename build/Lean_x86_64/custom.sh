#!/bin/bash

# ============ 基础配置 ============
echo "=== 开始自定义配置 ==="
WORKPATH=$(pwd)
echo "工作目录: $WORKPATH"

# ============ 创建自定义配置（第一步） ============
echo "=== 创建自定义网络配置文件 ==="

# 创建必要的目录结构
mkdir -p files/etc/config
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/rc.local
mkdir -p files/etc/pre_install

# 创建network配置文件 - 这会直接覆盖默认配置
cat > files/etc/config/network << 'EOF'
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fd4d:fd5c:ea76::/48'
    option packet_steering '1'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports 'eth0'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '172.18.18.222'   # 主IP地址
    option netmask '255.255.255.0'
    option gateway '172.18.18.2'    # 网关（主路由）
    list dns '223.5.5.5'
    list dns '119.29.29.29'
    option delegate '0'
    option force_link '1'

config interface 'wan'
    option device 'eth1'
    option proto 'dhcp'
    option peerdns '0'
    option delegate '0'

config interface 'wan6'
    option device 'eth1'
    option proto 'dhcpv6'
    option reqaddress 'try'
    option reqprefix 'auto'
    option delegate '0'
EOF

# 创建dhcp配置文件（旁路由模式关闭DHCP）
cat > files/etc/config/dhcp << 'EOF'
config dnsmasq
    option domainneeded '1'
    option boguspriv '1'
    option filterwin2k '0'
    option localise_queries '1'
    option rebind_protection '1'
    option rebind_localhost '1'
    option local '/lan/'
    option domain 'lan'
    option expandhosts '1'
    option nonegcache '0'
    option authoritative '1'
    option readethers '1'
    option leasefile '/tmp/dhcp.leases'
    option resolvfile '/tmp/resolv.conf.auto'
    option localservice '1'
    option ednspacket_max '1232'
    option filter_aaaa '1'  # 禁用IPv6解析

config dhcp 'lan'
    option interface 'lan'
    option start '100'
    option limit '150'
    option leasetime '12h'
    option dhcpv6 'disabled'
    option ra 'disabled'
    option ignore '1'         # 关键：关闭DHCP服务

config dhcp 'wan'
    option interface 'wan'
    option ignore '1'

config odhcpd 'odhcpd'
    option maindhcp '0'
    option leasefile '/tmp/hosts/odhcpd'
    option leasetrigger '/usr/sbin/odhcpd-update'
    option loglevel '4'
EOF

# 创建firewall配置文件
cat > files/etc/config/firewall << 'EOF'
config defaults
    option syn_flood '1'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option disable_ipv6 '1'

config zone
    option name 'lan'
    list network 'lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
    option masq '1'
    option mtu_fix '1'

config zone
    option name 'wan'
    list network 'wan'
    list network 'wan6'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '1'
    option mtu_fix '1'

config forwarding
    option src 'lan'
    option dest 'wan'

config rule
    option name 'Allow-DHCP-Renew'
    option src 'wan'
    option proto 'udp'
    option dest_port '68'
    option target 'ACCEPT'
    option family 'ipv4'

config rule
    option name 'Allow-Ping'
    option src 'wan'
    option proto 'icmp'
    option icmp_type 'echo-request'
    option family 'ipv4'
    option target 'ACCEPT'

config include
    option path '/etc/firewall.user'
EOF

# 创建rc.local文件，确保网络配置生效
cat > files/etc/rc.local << 'EOF'
#!/bin/sh -e
#
# rc.local - 开机自启动脚本
#

# 等待系统初始化完成
sleep 3

# 重启网络服务确保配置生效
echo "应用网络配置..."
/etc/init.d/network restart >/dev/null 2>&1

# 重启防火墙
echo "应用防火墙配置..."
/etc/init.d/firewall restart >/dev/null 2>&1

# 确保DHCP服务关闭
echo "关闭DHCP服务..."
/etc/init.d/dnsmasq disable >/dev/null 2>&1
/etc/init.d/dnsmasq stop >/dev/null 2>&1

# 设置正确的DNS
echo "设置DNS..."
echo "nameserver 223.5.5.5" > /tmp/resolv.conf.auto
echo "nameserver 119.29.29.29" >> /tmp/resolv.conf.auto

exit 0
EOF

chmod +x files/etc/rc.local

echo "=== 自定义配置文件创建完成 ==="

# ============ 安装额外依赖软件包 ============
# sudo -E apt-get -y install rename

# ============ 更新feeds文件 ============
cat feeds.conf.default

# ============ 添加第三方软件包 ============
git clone https://github.com/aoxijy/aoxi-package.git -b master package/aoxi-package

# ============ 更新并安装源 ============
./scripts/feeds clean
./scripts/feeds update -a && ./scripts/feeds install -a -f

# ============ 删除部分默认包 ============
rm -rf feeds/luci/applications/luci-app-qbittorrent
rm -rf feeds/luci/applications/luci-app-openclash
rm -rf feeds/luci/themes/luci-theme-argon

# ============ 创建预安装脚本 ============
echo "创建预安装目录和脚本..."

cat > files/etc/uci-defaults/98-pre_install << 'EOF'
#!/bin/sh

PKG_DIR="/etc/pre_install"

if [ -d "$PKG_DIR" ] && [ -n "$(ls -A $PKG_DIR 2>/dev/null)" ]; then

    echo "开始安装预置IPK包..."

    # 第一阶段：优先安装架构特定的包
    for pkg in $PKG_DIR/*_*.ipk; do
        if [ -f "$pkg" ]; then
            echo "优先安装基础包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends >/dev/null 2>&1
        fi
    done

    # 第二阶段：安装所有架构通用的包
    for pkg in $PKG_DIR/*_all.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装LuCI应用包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends >/dev/null 2>&1
        fi
    done

    # 第三阶段：安装语言包
    for pkg in $PKG_DIR/*_zh-cn.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装语言包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends >/dev/null 2>&1
        fi
    done    

    # 清理现场
    echo "预安装完成，清理临时文件..."
    rm -rf $PKG_DIR
fi

exit 0
EOF

chmod +x files/etc/uci-defaults/98-pre_install

# ============ 下载预安装的IPK包 ============
echo "下载预安装IPK包..."
# 示例：下载npc和luci-app-npc
wget -O files/etc/pre_install/npc_0.26.26-r16_x86_64.ipk https://example.com/path/to/npc_0.26.26-r16_x86_64.ipk || echo "npc包下载失败，将继续编译"
wget -O files/etc/pre_install/luci-app-npc_all.ipk https://example.com/path/to/luci-app-npc_all.ipk || echo "luci-app-npc包下载失败，将继续编译"

# ============ 自定义定制选项 ============
NET="package/base-files/files/bin/config_generate"
ZZZ="package/lean/default-settings/files/zzz-default-settings"

# 检查NET文件是否存在
if [ ! -f "$NET" ]; then
    echo "警告: 找不到 $NET，尝试其他路径..."
    NET2="package/base-files/files/etc/board.d/99-default_network"
    if [ -f "$NET2" ]; then
        NET="$NET2"
        echo "使用备用路径: $NET"
    else
        echo "警告: 无法找到网络配置文件"
    fi
fi

# 读取内核版本
if [ -f "target/linux/x86/Makefile" ]; then
    KERNEL_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_PATCHVER | sed 's/^.\{17\}//g')
    KERNEL_TESTING_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_TESTING_PATCHVER | sed 's/^.\{25\}//g')
    if [[ $KERNEL_TESTING_PATCHVER > $KERNEL_PATCHVER ]]; then
        echo "内核版本已更新为 $KERNEL_TESTING_PATCHVER"
    else
        echo "内核版本不需要更新"
    fi
fi

# ============ 修改系统配置 ============
# 注意：这里我们不修改默认IP，因为已经在files目录中配置了
# 只修改其他设置

# 修改默认名称
if [ -f "$NET" ]; then
    sed -i 's#LEDE#OpenWrt-GanQuanRu#g' $NET
    echo "已修改默认名称为 OpenWrt-GanQuanRu"
fi

# 修改默认密码
if [ -f "$ZZZ" ]; then
    sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' $ZZZ
    echo "已取消系统默认密码"
    
    # 添加个性名称
    CURRENT_DATE=$(TZ=UTC-8 date "+%Y.%m.%d")
    sed -i "s/LEDE /GanQuanRu build $CURRENT_DATE @ LEDE /g" $ZZZ
    echo "已添加个性名称"
    
    # 设置默认主题
    echo "uci set luci.main.mediaurlbase=/luci-static/argon" >> $ZZZ
    echo "已设置默认主题为argon"
fi

# ============ 其他系统定制 ============
# 修改默认时间格式
find package/lean/autocore/files/ -name "index.htm" -type f 2>/dev/null | while read file; do
    if [ -f "$file" ]; then
        sed -i 's#localtime  = os.date()#localtime  = os.date("%Y年%m月%d日") .. " " .. translate(os.date("%A")) .. " " .. os.date("%X")#g' "$file"
    fi
done

# 自定义banner显示
BANNER_FILE="package/base-files/files/etc/banner"
if [ -f "$BANNER_FILE" ]; then
    sed -i 's#%D %V, %C#%D %V, %C Lean_x86_64#g' "$BANNER_FILE"
fi

# ============ 添加基本配置到ZZZ ============
if [ -f "$ZZZ" ]; then
    cat >> $ZZZ << 'EOF'
# ============ 基本系统设置 ============
# 设置时区
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'

# 设置NTP服务器
uci set system.ntp.server='0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org 2.openwrt.pool.ntp.org 3.openwrt.pool.ntp.org'

# 设置语言
uci set luci.main.lang='zh_cn'

# 提交更改
uci commit system
uci commit luci
EOF
fi

# ============ OpenClash 配置 ============
# 检查.config文件是否存在
CONFIG_FILE=".config"
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$WORKPATH/.config"
fi

if [ -f "$CONFIG_FILE" ] && grep -q "CONFIG_PACKAGE_luci-app-openclash=y" "$CONFIG_FILE"; then
    echo "OpenClash 已启用，配置内核..."
    
    # 判断系统架构
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            arch="amd64"  # 默认
            ;;
    esac
    
    # 创建目录
    mkdir -p files/etc/openclash/core
    
    # 下载Meta内核
    echo "下载OpenClash Meta内核..."
    cd files/etc/openclash/core
    
    # 尝试多个下载源
    wget --timeout=30 --tries=2 -q https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$arch.tar.gz || \
    wget --timeout=30 --tries=2 -q https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/meta/clash-linux-$arch.tar.gz || \
    wget --timeout=30 --tries=2 -q https://ghproxy.com/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$arch.tar.gz
    
    if [ -f "clash-linux-$arch.tar.gz" ]; then
        echo "OpenClash Meta内核下载成功，开始解压..."
        tar -zxvf clash-linux-$arch.tar.gz >/dev/null 2>&1
        if [ -f "clash" ]; then
            mv clash clash_meta
            chmod +x clash_meta
            echo "✅ OpenClash Meta内核配置成功"
        else
            echo "⚠️ OpenClash Meta内核解压失败"
        fi
        rm -f clash-linux-$arch.tar.gz
    else
        echo "⚠️ OpenClash Meta内核下载失败"
    fi
    
    cd - >/dev/null
else
    echo "OpenClash 未启用编译"
    if [ -f "$ZZZ" ]; then
        echo 'rm -rf /etc/openclash 2>/dev/null' >> $ZZZ
    fi
fi

# ============ 清理ZZZ文件 ============
if [ -f "$ZZZ" ]; then
    # 移除多余的exit 0
    sed -i '/exit 0/d' $ZZZ
    # 确保最后有exit 0
    echo "exit 0" >> $ZZZ
fi

# ============ 验证配置 ============
echo ""
echo "=== 验证自定义配置 ==="
echo "1. 检查network配置:"
if [ -f "files/etc/config/network" ]; then
    echo "✅ 自定义network配置存在"
    echo "   IP地址: $(grep "option ipaddr" files/etc/config/network | head -1)"
else
    echo "❌ 自定义network配置不存在"
fi

echo ""
echo "2. 检查dhcp配置:"
if [ -f "files/etc/config/dhcp" ]; then
    echo "✅ 自定义dhcp配置存在"
    echo "   DHCP状态: $(grep "option ignore" files/etc/config/dhcp | head -1)"
else
    echo "❌ 自定义dhcp配置不存在"
fi

echo ""
echo "3. 检查文件结构:"
echo "   files/etc/config/network: $(ls -la files/etc/config/network 2>/dev/null | wc -l) 个文件"
echo "   files/etc/config/dhcp: $(ls -la files/etc/config/dhcp 2>/dev/null | wc -l) 个文件"
echo "   files/etc/config/firewall: $(ls -la files/etc/config/firewall 2>/dev/null | wc -l) 个文件"

echo ""
echo "=== 自定义配置完成 ==="

# ============ 创建.config文件 ============
cd $WORKPATH
touch ./.config

# ============ 固件配置 ============
cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
CONFIG_TARGET_KERNEL_PARTSIZE=16
CONFIG_TARGET_ROOTFS_PARTSIZE=360
CONFIG_TARGET_IMAGES_GZIP=y
CONFIG_EFI_IMAGES=y
CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y
CONFIG_PACKAGE_ipv6helper=y
CONFIG_QCOW2_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_VMDK_IMAGES=n
CONFIG_TARGET_IMAGES_PAD=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-easytier=y
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_trojan-go=y
CONFIG_PACKAGE_xray-plugin=y
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_luci-app-ssr-plus=y
CONFIG_PACKAGE_luci-app-filetransfer=y
CONFIG_PACKAGE_luci-app-wrtbwmon=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_wget=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_libcap=y
CONFIG_PACKAGE_libcap-bin=y
CONFIG_PACKAGE_ip6tables-mod-nat=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_autocore-x86=y
CONFIG_HAS_FPU=y
EOF

# ============ 清理.config格式 ============
sed -i 's/^[ \t]*//g' ./.config
sed -i '/^[[:space:]]*$/d' .config

echo ""
echo "=== 配置统计 ==="
echo "配置文件行数: $(wc -l .config | awk '{print $1}')"
echo "启用的功能数: $(grep -c "=y" .config)"

# 返回目录
cd $HOME
echo ""
echo "=== 脚本执行完成 ==="
