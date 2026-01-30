#!/bin/bash

# 更新feeds文件
cat feeds.conf.default

# 添加第三方软件包
git clone https://github.com/aoxijy/aoxi-package.git -b master package/aoxi-package

# 更新并安装源
./scripts/feeds clean
./scripts/feeds update -a && ./scripts/feeds install -a -f

# 删除部分默认包 (清理冲突)
rm -rf feeds/luci/applications/luci-app-qbittorrent
rm -rf feeds/luci/applications/luci-app-openclash
rm -rf feeds/luci/themes/luci-theme-argon
rm -rf feeds/packages/utils/fuse-overlayfs # 删除旧版本以防冲突

# 创建目录
echo "创建预安装目录..."
mkdir -p files/etc/pre_install
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/docker # 创建docker配置目录

# ●●●●●●●●●●●● 核心修复：自动配置 Docker 使用 fuse-overlayfs (无加速源版) ●●●●●●●●●●●●
cat > files/etc/uci-defaults/99-fix-docker-driver << 'EOF'
#!/bin/sh

# 1. 强制 dockerd 使用 fuse-overlayfs 驱动
# 不配置 registry-mirrors，使用默认源
mkdir -p /etc/docker
echo '{
  "storage-driver": "fuse-overlayfs",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}' > /etc/docker/daemon.json

# 2. 确保防火墙转发正常 (解决 Docker 网络不通问题)
uci set firewall.docker=include
uci set firewall.docker.type='script'
uci set firewall.docker.path='/etc/docker-init'
uci set firewall.docker.family='any'
uci set firewall.docker.reload='1'
uci commit firewall

# 3. 创建防火墙辅助脚本
cat > /etc/docker-init << 'DOCKERINIT'
#!/bin/sh
iptables -P FORWARD ACCEPT
DOCKERINIT
chmod +x /etc/docker-init

exit 0
EOF
chmod +x files/etc/uci-defaults/99-fix-docker-driver
# ●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●

# 创建预安装IPK脚本
cat > files/etc/uci-defaults/98-pre_install << 'EOF'
#!/bin/sh
PKG_DIR="/etc/pre_install"
if [ -d "$PKG_DIR" ] && [ -n "$(ls -A $PKG_DIR 2>/dev/null)" ]; then
    echo "开始安装预置IPK包..."
    opkg install $PKG_DIR/*.ipk --force-depends
    rm -rf $PKG_DIR
fi
exit 0
EOF
chmod +x files/etc/uci-defaults/98-pre_install

# 自定义定制选项
NET="package/base-files/luci2/bin/config_generate"
ZZZ="package/lean/default-settings/files/zzz-default-settings"

# 内核版本检查
KERNEL_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_PATCHVER | sed 's/^.\{17\}//g')
KERNEL_TESTING_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_TESTING_PATCHVER | sed 's/^.\{25\}//g')
if [[ $KERNEL_TESTING_PATCHVER > $KERNEL_PATCHVER ]]; then
  sed -i "s/$KERNEL_PATCHVER/$KERNEL_TESTING_PATCHVER/g" target/linux/x86/Makefile
  echo "内核版本已更新为 $KERNEL_TESTING_PATCHVER"
else
  echo "内核版本不需要更新"
fi

# 系统基础设置
sed -i 's#LEDE#OpenWrt-GanQuanRu#g' $NET
sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' $ZZZ
sed -i "s/LEDE /GanQuanRu build $(TZ=UTC-8 date "+%Y.%m.%d") @ LEDE /g" $ZZZ
echo "uci set luci.main.mediaurlbase=/luci-static/argon" >> $ZZZ
sed -i 's#localtime  = os.date()#localtime  = os.date("%Y年%m月%d日") .. " " .. translate(os.date("%A")) .. " " .. os.date("%X")#g' package/lean/autocore/files/*/index.htm
sed -i 's#%D %V, %C#%D %V, %C Lean_x86_64#g' package/base-files/files/etc/banner

# 网络设置
cat >> $ZZZ <<-EOF
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

# OpenClash 逻辑
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
    mkdir -p $HOME/clash-core
    mkdir -p $HOME/files/etc/openclash/core
    cd $HOME/clash-core
    wget -q https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$arch.tar.gz
    tar -zxvf clash-linux-$arch.tar.gz
    if [[ -f "$HOME/clash-core/clash" ]]; then
      mv -f $HOME/clash-core/clash $HOME/files/etc/openclash/core/clash_meta
      chmod +x $HOME/files/etc/openclash/core/clash_meta
    fi
    rm -rf $HOME/clash-core
  fi
fi

# 退出命令
cd $HOME && sed -i '/exit 0/d' $ZZZ && echo "exit 0" >> $ZZZ

# 创建配置文件
cd $WORKPATH
touch ./.config

# ●●●●●●●●●●●● 固件定制配置 (Docker 修复版) ●●●●●●●●●●●●

cat >> .config <<EOF
# 目标平台
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y

# 分区大小 (必须足够大，4G以上)
CONFIG_TARGET_KERNEL_PARTSIZE=64
CONFIG_TARGET_ROOTFS_PARTSIZE=4096

# 镜像特性
CONFIG_TARGET_IMAGES_GZIP=y
CONFIG_EFI_IMAGES=y
CONFIG_QCOW2_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_VMDK_IMAGES=n
CONFIG_TARGET_IMAGES_PAD=y

# IPv6 & Base
CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y
CONFIG_PACKAGE_ipv6helper=y

# ================= Docker 核心修复组件 =================
# 必须包含 fuse-overlayfs 和 kmod-fuse
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_kmod-fs-overlay=y
CONFIG_PACKAGE_kmod-fs-btrfs=y
CONFIG_PACKAGE_kmod-br-netfilter=y
CONFIG_PACKAGE_kmod-ipt-nat=y
CONFIG_PACKAGE_kmod-ikconfig=y
CONFIG_PACKAGE_kmod-cgroups=y
CONFIG_PACKAGE_cgroupfs-mount=y
CONFIG_PACKAGE_tini=y
# 关键修复包：
CONFIG_PACKAGE_fuse-overlayfs=y
CONFIG_PACKAGE_kmod-fuse=y
# =======================================================

# 插件列表
CONFIG_PACKAGE_luci-app-oaf=n 
CONFIG_PACKAGE_luci-app-openclash=y 
CONFIG_PACKAGE_luci-app-nikki=n 
CONFIG_PACKAGE_luci-app-eqos=n 
CONFIG_PACKAGE_luci-app-easytier=n
CONFIG_PACKAGE_luci-app-poweroff=n 
CONFIG_PACKAGE_luci-app-ssr-plus=y
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_trojan-go=y
CONFIG_PACKAGE_xray-plugin=y
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_luci-app-filetransfer=y
CONFIG_PACKAGE_luci-app-wrtbwmon=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-theme-design=y

# 基础工具
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
CONFIG_HAS_FPU=y
EOF

sed -i 's/^[ \t]*//g' ./.config

# 修复和清理配置
sed -i 's/^\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+\([^=]\)/\1=\2/g' .config
sed -i 's/^[[:space:]]*#*[[:space:]]*\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+is not set/# \1 is not set/g' .config
sed -i '/^[[:space:]]*$/d' .config

cd $HOME
