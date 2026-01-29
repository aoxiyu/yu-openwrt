#!/bin/bash

# 安装额外依赖软件包
# sudo -E apt-get -y install rename

# 更新feeds文件
# sed -i 's@#src-git helloworld@src-git helloworld@g' feeds.conf.default # 启用helloworld
# sed -i 's@src-git luci@# src-git luci@g' feeds.conf.default # 禁用18.06Luci
# sed -i 's@## src-git luci@src-git luci@g' feeds.conf.default # 启用23.05Luci
cat feeds.conf.default

# 添加第三方软件包
git clone https://github.com/aoxijy/aoxi-package.git -b master package/aoxi-package

# 更新并安装源
./scripts/feeds clean
./scripts/feeds update -a && ./scripts/feeds install -a -f

# 删除部分默认包
rm -rf feeds/luci/applications/luci-app-qbittorrent
rm -rf feeds/luci/applications/luci-app-openclash
rm -rf feeds/luci/themes/luci-theme-argon

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

    # 第一阶段：优先安装架构特定的包
    for pkg in $PKG_DIR/*x86_64.ipk; do 
        if [ -f "$pkg" ]; then 
            echo "优先安装基础包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第二阶段：安装所有架构通用的包
    for pkg in $PKG_DIR/*_all.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装LuCI应用包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第三阶段：安装语言包
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

# 下载预安装的IPK包 (示例代码保留)
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
NET="package/base-files/luci2/bin/config_generate"
ZZZ="package/lean/default-settings/files/zzz-default-settings"

# 读取内核版本并尝试更新
KERNEL_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_PATCHVER | sed 's/^.\{17\}//g')
KERNEL_TESTING_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_TESTING_PATCHVER | sed 's/^.\{25\}//g')
if [[ $KERNEL_TESTING_PATCHVER > $KERNEL_PATCHVER ]]; then
  sed -i "s/$KERNEL_PATCHVER/$KERNEL_TESTING_PATCHVER/g" target/linux/x86/Makefile        # 修改内核版本为最新
  echo "内核版本已更新为 $KERNEL_TESTING_PATCHVER"
else
  echo "内核版本不需要更新"
fi

# 系统基础设置
sed -i 's#LEDE#OpenWrt-GanQuanRu#g' $NET                                               # 修改默认名称
sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' $ZZZ                                         # 取消系统默认密码
sed -i "s/LEDE /GanQuanRu build $(TZ=UTC-8 date "+%Y.%m.%d") @ LEDE /g" $ZZZ          # 增加个性名称
echo "uci set luci.main.mediaurlbase=/luci-static/argon" >> $ZZZ                      # 设置默认主题

sed -i 's#localtime  = os.date()#localtime  = os.date("%Y年%m月%d日") .. " " .. translate(os.date("%A")) .. " " .. os.date("%X")#g' package/lean/autocore/files/*/index.htm                # 修改默认时间格式
sed -i 's#%D %V, %C#%D %V, %C Lean_x86_64#g' package/base-files/files/etc/banner                # 自定义banner显示

# ================ 网络设置 =======================================

cat >> $ZZZ <<-EOF
# 设置网络-旁路由模式
uci set network.lan.ipaddr='172.18.18.222'
uci set network.lan.gateway='172.18.18.2'                     # 旁路由设置 IPv4 网关
uci set network.lan.dns='223.5.5.5 119.29.29.29'            # 旁路由设置 DNS
uci set dhcp.lan.ignore='1'                                  # 旁路由关闭DHCP功能
uci delete network.lan.type                                  # 旁路由桥接模式-禁用
uci set network.lan.delegate='0'                             # 去掉LAN口使用内置的 IPv6 管理
uci set dhcp.@dnsmasq[0].filter_aaaa='0'                     # 禁止解析 IPv6 DNS记录

# 设置防火墙-旁路由模式
uci set firewall.@defaults[0].syn_flood='0'
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci set firewall.@defaults[0].fullcone='0'
uci set firewall.@defaults[0].fullcone6='0'
uci set firewall.@zone[0].masq='1'                             # 启用LAN口 IP 动态伪装

# 旁路IPV6需要全部禁用
uci del network.lan.ip6assign
uci del dhcp.lan.ra
uci del dhcp.lan.dhcpv6
uci del dhcp.lan.ra_management

uci commit dhcp
uci commit network
uci commit firewall
EOF

# =======================================================

# 检查 OpenClash 是否启用编译
if grep -qE '^(CONFIG_PACKAGE_luci-app-openclash=n|# CONFIG_PACKAGE_luci-app-openclash=)' "${WORKPATH}/$CUSTOM_SH"; then
  echo "OpenClash 未启用编译"
  echo 'rm -rf /etc/openclash' >> $ZZZ
else
  if grep -q "CONFIG_PACKAGE_luci-app-openclash=y" "${WORKPATH}/$CUSTOM_SH"; then
    arch=$(uname -m)
    case "$arch" in
      x86_64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
    esac
    echo "正在执行：为OpenClash下载内核"
    mkdir -p $HOME/clash-core
    mkdir -p $HOME/files/etc/openclash/core
    cd $HOME/clash-core
    wget -q https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$arch.tar.gz
    if [[ $? -ne 0 ]];then
      wget -q https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$arch.tar.gz
    else
      echo "OpenClash Meta内核压缩包下载成功，开始解压文件"
    fi
    tar -zxvf clash-linux-$arch.tar.gz
    if [[ -f "$HOME/clash-core/clash" ]]; then
      mv -f $HOME/clash-core/clash $HOME/files/etc/openclash/core/clash_meta
      chmod +x $HOME/files/etc/openclash/core/clash_meta
      echo "OpenClash Meta内核配置成功"
    else
      echo "OpenClash Meta内核配置失败"
    fi
    rm -rf $HOME/clash-core
  fi
fi

# =======================================================

# 修改退出命令到最后
cd $HOME && sed -i '/exit 0/d' $ZZZ && echo "exit 0" >> $ZZZ


# 创建自定义配置文件
cd $WORKPATH
touch ./.config

#
# ●●●●●●●●●●●●●●●●●●●●●●●●固件定制部分●●●●●●●●●●●●●●●●●●●●●●●●
# 

# 编译x64固件:
cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
EOF

# 设置固件大小 (重要修改：扩大分区以容纳Docker):
cat >> .config <<EOF
CONFIG_TARGET_KERNEL_PARTSIZE=64
CONFIG_TARGET_ROOTFS_PARTSIZE=4096
EOF

# 固件压缩:
cat >> .config <<EOF
CONFIG_TARGET_IMAGES_GZIP=y
EOF

# 编译UEFI固件:
cat >> .config <<EOF
CONFIG_EFI_IMAGES=y
EOF

# IPv6支持:
cat >> .config <<EOF
CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y
CONFIG_PACKAGE_ipv6helper=y
EOF

# 虚拟化镜像格式
cat >> .config <<EOF
CONFIG_QCOW2_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_VMDK_IMAGES=n
CONFIG_TARGET_IMAGES_PAD=y
EOF

# 第三方插件选择:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-oaf=n 
CONFIG_PACKAGE_luci-app-openclash=y 
CONFIG_PACKAGE_luci-app-nikki=n 
CONFIG_PACKAGE_luci-app-eqos=n 
CONFIG_PACKAGE_luci-app-easytier=n
CONFIG_PACKAGE_luci-app-poweroff=n 
EOF

# ShadowsocksR插件:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-ssr-plus=y
# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_SagerNet_Core is not set
EOF

# Passwall插件:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_trojan-go=y
CONFIG_PACKAGE_xray-plugin=y
CONFIG_PACKAGE_shadowsocks-rust-sslocal=n
EOF

# Turbo ACC:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-turboacc=y
EOF

# 常用LuCI插件:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-ddns=n
CONFIG_PACKAGE_luci-app-vlmcsd=n
CONFIG_DEFAULT_luci-app-vlmcsd=n
CONFIG_PACKAGE_luci-app-filetransfer=y
CONFIG_PACKAGE_luci-app-autoreboot=n
CONFIG_PACKAGE_luci-app-upnp=n
CONFIG_PACKAGE_luci-app-arpbind=n
CONFIG_PACKAGE_luci-app-accesscontrol=n
CONFIG_PACKAGE_luci-app-wol=n
CONFIG_PACKAGE_luci-app-nps=n
CONFIG_PACKAGE_luci-app-frpc=n
CONFIG_PACKAGE_luci-app-nlbwmon=n
CONFIG_PACKAGE_luci-app-wrtbwmon=y
CONFIG_PACKAGE_luci-app-haproxy-tcp=n
CONFIG_PACKAGE_luci-app-diskman=n
CONFIG_PACKAGE_luci-app-transmission=n
CONFIG_PACKAGE_luci-app-qbittorrent=n
CONFIG_PACKAGE_luci-app-amule=n
CONFIG_PACKAGE_luci-app-xlnetacc=n
CONFIG_PACKAGE_luci-app-zerotier=n
CONFIG_PACKAGE_luci-app-hd-idle=n
CONFIG_PACKAGE_luci-app-unblockmusic=n
CONFIG_PACKAGE_luci-app-airplay2=n
CONFIG_PACKAGE_luci-app-music-remote-center=n
CONFIG_PACKAGE_luci-app-usb-printer=n
CONFIG_PACKAGE_luci-app-sqm=n
CONFIG_PACKAGE_luci-app-jd-dailybonus=n
CONFIG_PACKAGE_luci-app-uugamebooster=n
CONFIG_PACKAGE_luci-app-ttyd=n
CONFIG_PACKAGE_luci-app-wireguard=n
CONFIG_PACKAGE_luci-app-v2ray-server=n
CONFIG_PACKAGE_luci-app-pptp-server=n
CONFIG_PACKAGE_luci-app-ipsec-vpnd=n
CONFIG_PACKAGE_luci-app-openvpn-server=n
CONFIG_PACKAGE_luci-app-softethervpn=n
CONFIG_PACKAGE_luci-app-minidlna=n
CONFIG_PACKAGE_luci-app-vsftpd=n
CONFIG_PACKAGE_luci-app-samba=n
CONFIG_PACKAGE_autosamba=n
CONFIG_PACKAGE_samba36-server=n
EOF

# ==========================================
# Docker 专属配置 (核心修复部分)
# ==========================================
cat >> .config <<EOF
# Docker 核心组件
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_luci-app-dockerman=y

# Docker 必须的内核模块 (解决 overlay mount invalid argument)
CONFIG_PACKAGE_kmod-fs-overlay=y
CONFIG_PACKAGE_kmod-fs-btrfs=y
CONFIG_PACKAGE_kmod-br-netfilter=y
CONFIG_PACKAGE_kmod-ipt-nat=y
CONFIG_PACKAGE_kmod-ikconfig=y
CONFIG_PACKAGE_kmod-cgroups=y
CONFIG_PACKAGE_cgroupfs-mount=y

# 容器工具
CONFIG_PACKAGE_tini=y
EOF

# LuCI主题:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-theme-design=y
EOF

# 常用软件包:
cat >> .config <<EOF
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
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
EOF

# 其他软件包:
cat >> .config <<EOF
CONFIG_HAS_FPU=y
EOF

# 
# ●●●●●●●●●●●●●●●●●●●●●●●●固件定制部分结束●●●●●●●●●●●●●●●●●●●●●●●● #
# 

sed -i 's/^[ \t]*//g' ./.config

# 修复和调试
echo "=== 原始配置行数: $(wc -l .config) ==="
# 自动修复常见语法错误
sed -i 's/^\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+\([^=]\)/\1=\2/g' .config
sed -i 's/^[[:space:]]*#*[[:space:]]*\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+is not set/# \1 is not set/g' .config
sed -i '/^[[:space:]]*$/d' .config

echo "=== 修复完成 ==="

# 返回目录
cd $HOME
