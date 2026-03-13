#!/bin/bash

# 安装额外依赖软件包
# sudo -E apt-get -y install rename

# 更新feeds文件
# sed -i 's@#src-git helloworld@src-git helloworld@g' feeds.conf.default # 启用helloworld
# sed -i 's@src-git luci@# src-git luci@g' feeds.conf.default # 禁用18.06Luci
# sed -i 's@## src-git luci@src-git luci@g' feeds.conf.default # 启用23.05Luci
cat feeds.conf.default

# 更新并安装源
# ./scripts/feeds clean
./scripts/feeds update

# 添加第三方软件包
git clone https://github.com/aoxijy/aoxi-package.git -b master package/aoxi-package

# 删除部分默认包
rm -rf feeds/luci/applications/luci-app-qbittorrent
rm -rf feeds/luci/applications/luci-app-openclash
rm -rf feeds/luci/themes/luci-theme-argon

# 安装源
./scripts/feeds install -a -f

# 创建预安装目录和脚本
echo "创建预安装目录和脚本..."
mkdir -p files/etc/pre_install
mkdir -p files/etc/uci-defaults

# 创建预安装脚本
cat > files/etc/uci-defaults/98-pre_install << 'EOF'
#!/bin/sh

PKG_DIR="/etc/pre_install"

if [ -d "$PKG_DIR" ] && [ -n "$(ls -A $PKG_DIR 2>/dev/null)" ]; then

    echo "开始安装预置IPK包..."

    # 第一阶段：优先安装架构特定的包 (e.g., npc_0.26.26-r16_x86_64.ipk)
    for pkg in $PKG_DIR/*x86_64.ipk; do
        if [ -f "$pkg" ]; then
            echo "优先安装基础包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第二阶段：安装所有架构通用的包 (e.g., luci-app-npc_all.ipk)
    for pkg in $PKG_DIR/*_all.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装LuCI应用包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第三阶段：安装语言包 (e.g., luci-i18n-easytier_zh-cn.ipk)
    for pkg in $PKG_DIR/*_zh-cn.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装LuCI应用包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done    

    # 清理现场
    echo "预安装完成，清理临时文件..."
    rm -rf $PKG_DIR
fi

exit 0
EOF

# 设置预安装脚本权限
chmod +x files/etc/uci-defaults/98-pre_install

# 下载预安装的IPK包（请替换为真实可用的URL）
echo "下载预安装IPK包..."
wget -O files/etc/pre_install/npc_0.26.26-r16_x86_64.ipk https://example.com/path/to/npc_0.26.26-r16_x86_64.ipk || echo "npc包下载失败，将继续编译"
wget -O files/etc/pre_install/luci-app-npc_all.ipk https://example.com/path/to/luci-app-npc_all.ipk || echo "luci-app-npc包下载失败，将继续编译"

# 检查下载是否成功
if [ ! -f "files/etc/pre_install/npc_0.26.26-r16_x86_64.ipk" ]; then
    echo "警告: npc包下载失败! 预安装将跳过此包"
fi
if [ ! -f "files/etc/pre_install/luci-app-npc_all.ipk" ]; then
    echo "警告: luci-app-npc包下载失败! 预安装将跳过此包"
fi

# 自定义定制选项
NET="package/base-files/files/bin/config_generate"   # 修正路径
ZZZ="package/lean/default-settings/files/zzz-default-settings"

# 读取内核版本
KERNEL_PATCHVER=$(cat target/linux/x86/Makefile | grep KERNEL_PATCHVER | sed 's/^.\{17\}//g')
KERNEL_TESTING_PATCHVER=$(cat target/linux/x86/Makefile | grep KERNEL_TESTING_PATCHVER | sed 's/^.\{25\}//g')
if [[ $KERNEL_TESTING_PATCHVER > $KERNEL_PATCHVER ]]; then
    # 转义点号避免正则解析问题
    sed -i "s/${KERNEL_PATCHVER//./\\.}/${KERNEL_TESTING_PATCHVER//./\\.}/g" target/linux/x86/Makefile
    echo "内核版本已更新为 $KERNEL_TESTING_PATCHVER"
else
    echo "内核版本不需要更新"
fi

# 修改默认配置
sed -i 's#LEDE#OpenWrt-GanQuanRu#g' $NET
sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' $ZZZ
sed -i "s/LEDE /GanQuanRu build $(TZ=UTC-8 date "+%Y.%m.%d") @ LEDE /g" $ZZZ
echo "uci set luci.main.mediaurlbase=/luci-static/argon" >> $ZZZ

# 修改时间格式等
sed -i 's#localtime  = os.date()#localtime  = os.date("%Y年%m月%d日") .. " " .. translate(os.date("%A")) .. " " .. os.date("%X")#g' package/lean/autocore/files/*/index.htm
sed -i 's#%D %V, %C#%D %V, %C Lean_x86_64#g' package/base-files/files/etc/banner

# 添加网络设置到 zzz-default-settings
cat >> $ZZZ <<-EOF
# 设置网络-旁路由模式
uci set network.lan.ipaddr='172.18.18.222'
uci set network.lan.gateway='172.18.18.2'
uci set network.lan.dns='223.5.5.5 119.29.29.29'
uci set dhcp.lan.ignore='1'
uci delete network.lan.type
uci set network.lan.delegate='0'
uci set dhcp.@dnsmasq[0].filter_aaaa='0'

uci set firewall.@defaults[0].syn_flood='0'
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci set firewall.@defaults[0].fullcone='0'
uci set firewall.@defaults[0].fullcone6='0'
uci set firewall.@zone[0].masq='1'

uci del network.lan.ip6assign
uci del dhcp.lan.ra
uci del dhcp.lan.dhcpv6
uci del dhcp.lan.ra_management

uci commit dhcp
uci commit network
uci commit firewall
EOF

# 生成 .config 配置
# 注意：此部分会生成完整的 .config，工作流中不再覆盖
cd "$WORKPATH"   # 确保在 WORKPATH 下生成 .config，但实际会在 openwrt 根目录？我们统一在 openwrt 根目录操作
# 回到 openwrt 根目录
cd "$HOME"

# 基础配置
cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
CONFIG_TARGET_KERNEL_PARTSIZE=16
CONFIG_TARGET_ROOTFS_PARTSIZE=360
CONFIG_TARGET_IMAGES_GZIP=y
CONFIG_EFI_IMAGES=y
# CONFIG_QCOW2_IMAGES is not set
# CONFIG_VHDX_IMAGES is not set
# CONFIG_VMDK_IMAGES is not set
CONFIG_TARGET_IMAGES_PAD=y
CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y
CONFIG_PACKAGE_ipv6helper=y
EOF

# 第三方插件选择（禁用用 # CONFIG_... is not set）
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-oaf is not set
CONFIG_PACKAGE_luci-app-openclash=y
# CONFIG_PACKAGE_luci-app-nikki is not set
# CONFIG_PACKAGE_luci-app-serverchan is not set
# CONFIG_PACKAGE_luci-app-eqos is not set
# CONFIG_PACKAGE_luci-app-easytier is not set
# CONFIG_PACKAGE_luci-app-control-weburl is not set
# CONFIG_PACKAGE_luci-app-smartdns is not set
# CONFIG_PACKAGE_luci-app-adguardhome is not set
# CONFIG_PACKAGE_luci-app-poweroff is not set
# CONFIG_PACKAGE_luci-app-argon-config is not set
# CONFIG_PACKAGE_luci-app-autotimeset is not set
# CONFIG_PACKAGE_luci-app-ddnsto is not set
# CONFIG_PACKAGE_ddnsto is not set
EOF

# ShadowsocksR
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-ssr-plus=y
# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_SagerNet_Core is not set
EOF

# 禁用 Dropbear，启用 OpenSSH
cat >> .config <<EOF
# CONFIG_PACKAGE_dropbear is not set
CONFIG_PACKAGE_openssh-server=y
CONFIG_PACKAGE_openssh-sftp-server=y
EOF

# 禁用 uhttpd，启用 nginx
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-light is not set
# CONFIG_PACKAGE_uhttpd is not set
# CONFIG_PACKAGE_uhttpd-mod-ubus is not set
CONFIG_PACKAGE_luci-nginx=y
CONFIG_PACKAGE_nginx-util=y
EOF

# Passwall
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-passwall=y
# CONFIG_PACKAGE_luci-app-passwall2 is not set
# CONFIG_PACKAGE_naiveproxy is not set
CONFIG_PACKAGE_chinadns-ng=y
# CONFIG_PACKAGE_brook is not set
CONFIG_PACKAGE_trojan-go=y
# CONFIG_PACKAGE_xray-plugin is not set
# CONFIG_PACKAGE_shadowsocks-rust-sslocal is not set
EOF

# Turbo ACC
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-turboacc=y
EOF

# 常用 LuCI 插件
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-adbyby-plus is not set
# CONFIG_PACKAGE_luci-app-webadmin is not set
# CONFIG_PACKAGE_luci-app-ddns is not set
# CONFIG_PACKAGE_luci-app-vlmcsd is not set
CONFIG_PACKAGE_luci-app-filetransfer=y
# CONFIG_PACKAGE_luci-app-autoreboot is not set
# CONFIG_PACKAGE_luci-app-upnp is not set
# CONFIG_PACKAGE_luci-app-arpbind is not set
# CONFIG_PACKAGE_luci-app-accesscontrol is not set
# CONFIG_PACKAGE_luci-app-wol is not set
# CONFIG_PACKAGE_luci-app-nps is not set
# CONFIG_PACKAGE_luci-app-frpc is not set
# CONFIG_PACKAGE_luci-app-nlbwmon is not set
CONFIG_PACKAGE_luci-app-wrtbwmon=y
# CONFIG_PACKAGE_luci-app-haproxy-tcp is not set
CONFIG_PACKAGE_luci-app-diskman=y
# CONFIG_PACKAGE_luci-app-transmission is not set
# CONFIG_PACKAGE_luci-app-qbittorrent is not set
# CONFIG_PACKAGE_luci-app-amule is not set
# CONFIG_PACKAGE_luci-app-xlnetacc is not set
# CONFIG_PACKAGE_luci-app-zerotier is not set
# CONFIG_PACKAGE_luci-app-hd-idle is not set
# CONFIG_PACKAGE_luci-app-unblockmusic is not set
# CONFIG_PACKAGE_luci-app-airplay2 is not set
# CONFIG_PACKAGE_luci-app-music-remote-center is not set
# CONFIG_PACKAGE_luci-app-usb-printer is not set
# CONFIG_PACKAGE_luci-app-sqm is not set
# CONFIG_PACKAGE_luci-app-jd-dailybonus is not set
# CONFIG_PACKAGE_luci-app-uugamebooster is not set
# CONFIG_PACKAGE_luci-app-dockerman is not set
# CONFIG_PACKAGE_luci-app-ttyd is not set
# CONFIG_PACKAGE_luci-app-wireguard is not set
EOF

# VPN 相关（禁用）
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-v2ray-server is not set
# CONFIG_PACKAGE_luci-app-pptp-server is not set
# CONFIG_PACKAGE_luci-app-ipsec-vpnd is not set
# CONFIG_PACKAGE_luci-app-openvpn-server is not set
# CONFIG_PACKAGE_luci-app-softethervpn is not set
EOF

# 文件共享（禁用）
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-minidlna is not set
# CONFIG_PACKAGE_luci-app-vsftpd is not set
# CONFIG_PACKAGE_luci-app-samba is not set
# CONFIG_PACKAGE_autosamba is not set
# CONFIG_PACKAGE_samba36-server is not set
EOF

# LuCI 主题
cat >> .config <<EOF
CONFIG_PACKAGE_luci-theme-argon=y
# CONFIG_PACKAGE_luci-theme-design is not set
EOF

# 常用软件包
cat >> .config <<EOF
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
# CONFIG_PACKAGE_screen is not set
# CONFIG_PACKAGE_tree is not set
# CONFIG_PACKAGE_vim-fuller is not set
CONFIG_PACKAGE_wget=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_snmpd=y
CONFIG_PACKAGE_libcap=y
CONFIG_PACKAGE_libcap-bin=y
CONFIG_PACKAGE_ip6tables-mod-nat=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_vsftpd=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_qemu-ga=y
CONFIG_PACKAGE_autocore-x86=y
CONFIG_HAS_FPU=y
EOF

# 修复和调试（可选）
echo "=== 原始配置行数: $(wc -l .config) ==="

# 移除行首空格
sed -i 's/^[ \t]*//g' ./.config

echo "=== 修复后的第60-70行内容 ==="
sed -n '60,70p' .config
echo "=== 修复完成 ==="

# -------------------------------------------------
# OpenClash 内核下载（在 .config 生成之后，根据实际启用状态）
if grep -q "^CONFIG_PACKAGE_luci-app-openclash=y" ".config"; then
    echo "检测到 OpenClash 已启用，开始下载内核..."
    mkdir -p files/etc/openclash/core
    arch="amd64"   # 当前目标为 x86_64
    KERNEL_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${arch}.tar.gz"
    wget -q "$KERNEL_URL" -O /tmp/clash-meta.tar.gz
    if [ $? -eq 0 ] && [ -s /tmp/clash-meta.tar.gz ]; then
        tar -xzf /tmp/clash-meta.tar.gz -C files/etc/openclash/core/
        if [ -f files/etc/openclash/core/clash ]; then
            mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
            chmod +x files/etc/openclash/core/clash_meta
            echo "OpenClash Meta 内核配置成功"
        else
            echo "OpenClash Meta 内核解压失败"
        fi
        rm -f /tmp/clash-meta.tar.gz
    else
        echo "OpenClash Meta 内核下载失败，请检查网络或更换下载源"
    fi
fi

# 修改退出命令到最后（确保 exit 0 存在）
sed -i '/exit 0/d' $ZZZ
echo "exit 0" >> $ZZZ

# 无需 cd $HOME，因为已经在 openwrt 根目录
