#!/bin/bash

# ============================================
# 集中配置区域
# ============================================

# Docker配置
ENABLE_DOCKER="y"  # y: 启用Docker, n: 禁用Docker
DOCKER_STORAGE_DRIVER="overlay2"  # overlay2, vfs, aufs
DOCKER_DATA_ROOT="/opt/docker"

# OpenWrt网络配置
OPENWRT_IP="172.18.18.222"
OPENWRT_GATEWAY="172.18.18.2"
OPENWRT_DNS="223.5.5.5 119.29.29.29"

# 工作路径变量
WORKPATH=$(pwd)
CUSTOM_SH="custom.sh"  # 根据实际情况调整

# ============================================
# 以下为原始脚本内容...
# ============================================

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

    # 第一阶段：优先安装架构特定的包 (e.g., npc_0.26.26-r16_x86_64.ipk)
    # 这些通常是基础程序或内核模块，LuCI包依赖它们。
    for pkg in $PKG_DIR/*x86_64.ipk; do # 模式匹配包含下划线_的包名
        if [ -f "$pkg" ]; then # 确保是文件，防止没匹配到时循环到通配符本身
            echo "优先安装基础包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第二阶段：安装所有架构通用的包 (e.g., luci-app-npc_all.ipk)
    # 这些通常是LuCI界面、主题或脚本，它们依赖第一阶段安装的包。
    for pkg in $PKG_DIR/*_all.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装LuCI应用包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第三阶段：安装所有架构通用的包 (e.g., luci-i18n-easytier_zh-cn.ipk)
    # 这些通常是LuCI界面、主题或脚本，它们依赖第一阶段安装的包。
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

# 下载预安装的IPK包
echo "下载预安装IPK包..."
# 示例：下载npc和luci-app-npc
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

# 读取内核版本
KERNEL_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_PATCHVER | sed 's/^.\{17\}//g')
KERNEL_TESTING_PATCHVER=$(cat target/linux/x86/Makefile|grep KERNEL_TESTING_PATCHVER | sed 's/^.\{25\}//g')

echo "当前内核版本: $KERNEL_PATCHVER"
echo "测试内核版本: $KERNEL_TESTING_PATCHVER"

# 自动更新到最新内核版本（保持原有逻辑）
if [[ $KERNEL_TESTING_PATCHVER > $KERNEL_PATCHVER ]]; then
  sed -i "s/$KERNEL_PATCHVER/$KERNEL_TESTING_PATCHVER/g" target/linux/x86/Makefile
  KERNEL_PATCHVER=$KERNEL_TESTING_PATCHVER
  echo "内核版本已更新为 $KERNEL_PATCHVER"
else
  echo "内核版本不需要更新"
fi

# ============================================
# Docker内核支持配置（必须放在内核版本读取之后）
# ============================================

if [ "$ENABLE_DOCKER" = "y" ]; then
    echo "配置Docker内核支持（内核版本: $KERNEL_PATCHVER）..."
    
    DOCKER_KERNEL_CONFIG="target/linux/x86/config-${KERNEL_PATCHVER}"
    
    if [ -f "$DOCKER_KERNEL_CONFIG" ]; then
        echo "为Docker添加overlayfs内核支持到: $DOCKER_KERNEL_CONFIG"
        
        # 备份原始配置
        cp "$DOCKER_KERNEL_CONFIG" "${DOCKER_KERNEL_CONFIG}.backup"
        
        # 清理现有的overlay配置
        sed -i '/CONFIG_OVERLAY_FS/d' "$DOCKER_KERNEL_CONFIG"
        sed -i '/CONFIG_OVERLAY_FS_REDIRECT_DIR/d' "$DOCKER_KERNEL_CONFIG"
        sed -i '/CONFIG_OVERLAY_FS_INDEX/d' "$DOCKER_KERNEL_CONFIG"
        sed -i '/CONFIG_OVERLAY_FS_METACOPY/d' "$DOCKER_KERNEL_CONFIG"
        
        # 添加Docker必需的overlayfs配置
        echo "# Docker overlayfs支持" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_OVERLAY_FS=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_OVERLAY_FS_REDIRECT_DIR=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_OVERLAY_FS_INDEX=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_OVERLAY_FS_METACOPY=y" >> "$DOCKER_KERNEL_CONFIG"
        
        # 其他必需的内核配置（适用于6.x内核）
        echo "# Docker其他必需配置" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_USER_NS=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_CGROUP_DEVICE=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_CGROUP_PIDS=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_MEMCG=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_VETH=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_BRIDGE=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_NF_NAT=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_NF_NAT_IPV4=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_NF_NAT_IPV6=y" >> "$DOCKER_KERNEL_CONFIG"
        
        # 6.x内核通用配置
        echo "# 6.x内核通用配置" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_CGROUP_BPF=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_BPF_SYSCALL=y" >> "$DOCKER_KERNEL_CONFIG"
        echo "CONFIG_CGROUP_FREEZER=y" >> "$DOCKER_KERNEL_CONFIG"
        
        echo "Docker内核配置已更新"
    else
        echo "警告：内核配置文件 $DOCKER_KERNEL_CONFIG 不存在"
        echo "尝试寻找其他配置文件..."
        ALT_CONFIG=$(find target/linux/x86 -name "config-*" | head -1)
        if [ -f "$ALT_CONFIG" ]; then
            echo "使用备选配置文件: $ALT_CONFIG"
            DOCKER_KERNEL_CONFIG="$ALT_CONFIG"
            # 在这里可以添加配置，或者只是记录日志
        fi
    fi
fi

# ============================================
# 基础配置
# ============================================

# sed -i 's#192.168.1.1#172.18.18.222#g' $NET  # 定制默认IP
sed -i 's#LEDE#OpenWrt-GanQuanRu#g' $NET  # 修改默认名称为OpenWrt-X86
sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' $ZZZ  # 取消系统默认密码
sed -i "s/LEDE /GanQuanRu build $(TZ=UTC-8 date "+%Y.%m.%d") @ LEDE /g" $ZZZ  # 增加自己个性名称
echo "uci set luci.main.mediaurlbase=/luci-static/argon" >> $ZZZ  # 设置默认主题

# ●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●● #

sed -i 's#localtime  = os.date()#localtime  = os.date("%Y年%m月%d日") .. " " .. translate(os.date("%A")) .. " " .. os.date("%X")#g' package/lean/autocore/files/*/index.htm  # 修改默认时间格式
sed -i 's#%D %V, %C#%D %V, %C Lean_x86_64#g' package/base-files/files/etc/banner  # 自定义banner显示

# ●●●●●●●●●●●●●●●●●●●●●●●●定制部分●●●●●●●●●●●●●●●●●●●●●●●● #

# ================ 网络设置 =======================================

cat >> $ZZZ <<-EOF
# 设置网络-旁路由模式
uci set network.lan.ipaddr='172.18.18.222'
uci set network.lan.gateway='172.18.18.2'                     # 旁路由设置 IPv4 网关
uci set network.lan.dns='223.5.5.5 119.29.29.29'            # 旁路由设置 DNS(多个DNS要用空格分开)
uci set dhcp.lan.ignore='1'                                  # 旁路由关闭DHCP功能
uci delete network.lan.type                                  # 旁路由桥接模式-禁用
uci set network.lan.delegate='0'                             # 去掉LAN口使用内置的 IPv6 管理(若用IPV6请把'0'改'1')
uci set dhcp.@dnsmasq[0].filter_aaaa='0'                     # 禁止解析 IPv6 DNS记录(若用IPV6请把'1'改'0')

# 设置防火墙-旁路由模式
uci set firewall.@defaults[0].syn_flood='0'                  # 禁用 SYN-flood 防御
uci set firewall.@defaults[0].flow_offloading='0'           # 禁用基于软件的NAT分载
uci set firewall.@defaults[0].flow_offloading_hw='0'       # 禁用基于硬件的NAT分载
uci set firewall.@defaults[0].fullcone='0'                   # 禁用 FullCone NAT
uci set firewall.@defaults[0].fullcone6='0'                  # 禁用 FullCone NAT6
uci set firewall.@zone[0].masq='1'                             # 启用LAN口 IP 动态伪装

# 旁路IPV6需要全部禁用
uci del network.lan.ip6assign                                 # IPV6分配长度-禁用
uci del dhcp.lan.ra                                             # 路由通告服务-禁用
uci del dhcp.lan.dhcpv6                                        # DHCPv6 服务-禁用
uci del dhcp.lan.ra_management                               # DHCPv6 模式-禁用

# 如果有用IPV6的话,可以使用以下命令创建IPV6客户端(LAN口)（去掉全部代码uci前面#号生效）
uci set network.ipv6=interface
uci set network.ipv6.proto='dhcpv6'
uci set network.ipv6.ifname='@lan'
uci set network.ipv6.reqaddress='try'
uci set network.ipv6.reqprefix='auto'
uci set firewall.@zone[0].network='lan ipv6'

uci commit dhcp
uci commit network
uci commit firewall

EOF

# =======================================================

# 检查 OpenClash 是否启用编译
if grep -qE '^(CONFIG_PACKAGE_luci-app-openclash=n|# CONFIG_PACKAGE_luci-app-openclash=)' "${WORKPATH}/$CUSTOM_SH" 2>/dev/null; then
    # OpenClash 未启用，不执行任何操作
    echo "OpenClash 未启用编译"
    echo 'rm -rf /etc/openclash' >> $ZZZ
else
    # OpenClash 已启用，执行配置
    if grep -q "CONFIG_PACKAGE_luci-app-openclash=y" .config 2>/dev/null || \
       grep -q "CONFIG_PACKAGE_luci-app-openclash=y" "${WORKPATH}/$CUSTOM_SH" 2>/dev/null; then
        # 判断系统架构
        arch=$(uname -m)  # 获取系统架构
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
        # OpenClash Meta 开始配置内核
        echo "正在执行：为OpenClash下载内核"
        mkdir -p $HOME/clash-core
        mkdir -p $HOME/files/etc/openclash/core
        cd $HOME/clash-core
        # 下载Meta内核
        wget -q https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$arch.tar.gz
        if [[ $? -ne 0 ]]; then
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
        rm -rf $HOME/clash-core/clash-linux-$arch.tar.gz
        rm -rf $HOME/clash-core
    fi
fi

# =======================================================
# Docker配置（如果启用）
# =======================================================

if [ "$ENABLE_DOCKER" = "y" ]; then
    echo "配置Docker存储驱动..."
    cat >> $ZZZ << 'EOF'

# Docker配置
uci set docker.globals='globals'
uci set docker.globals.data_root='/opt/docker'
uci set docker.globals.log_level='warn'
uci set docker.globals.iptables='1'
uci set docker.globals.ipv6='0'
uci set docker.globals.debug='0'
uci set docker.globals.storage_driver='overlay2'
uci set docker.globals.userland_proxy='0'

# 创建Docker目录
mkdir -p /opt/docker
mkdir -p /etc/docker

# Docker守护进程配置
cat > /etc/docker/daemon.json << DOCKEREOF
{
  "data-root": "/opt/docker",
  "log-level": "warn",
  "iptables": true,
  "ipv6": false,
  "debug": false,
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true",
    "overlay2.skip_mount_home=true"
  ],
  "exec-opts": [
    "native.cgroupdriver=cgroupfs"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
DOCKEREOF

# 加载必要的内核模块
insmod overlay 2>/dev/null || true
insmod br_netfilter 2>/dev/null || true
insmod veth 2>/dev/null || true

# 启用IP转发和桥接
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables

# 设置开机加载模块
mkdir -p /etc/modules.d
echo overlay > /etc/modules.d/50-docker
echo br_netfilter >> /etc/modules.d/50-docker
echo veth >> /etc/modules.d/50-docker

# 测试overlay文件系统
mkdir -p /tmp/test-overlay/{lower,upper,work,merged}
if mount -t overlay overlay -o lowerdir=/tmp/test-overlay/lower,upperdir=/tmp/test-overlay/upper,workdir=/tmp/test-overlay/work /tmp/test-overlay/merged 2>/dev/null; then
    echo "overlay文件系统测试成功"
    umount /tmp/test-overlay/merged
    rm -rf /tmp/test-overlay
else
    echo "警告: overlay文件系统测试失败，将尝试使用vfs驱动"
    # 如果overlay失败，回退到vfs
    sed -i 's/"storage-driver": "overlay2"/"storage-driver": "vfs"/g' /etc/docker/daemon.json
    sed -i 's/uci set docker.globals.storage_driver='"'"'overlay2'"'"'/uci set docker.globals.storage_driver='"'"'vfs'"'"'/g' /etc/config/docker 2>/dev/null || true
fi

# 启动Docker服务
/etc/init.d/docker enable
/etc/init.d/docker start 2>/dev/null || true

EOF
fi

# =======================================================

# 修改退出命令到最后
cd $HOME && sed -i '/exit 0/d' $ZZZ && echo "exit 0" >> $ZZZ

# ●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●● #

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

# 设置固件大小:
cat >> .config <<EOF
CONFIG_TARGET_KERNEL_PARTSIZE=32
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
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

# 编译PVE/KVM、Hyper-V、VMware镜像以及镜像填充
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

# Turbo ACC 网络加速:
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
CONFIG_PACKAGE_luci-app-diskman=y
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
CONFIG_PACKAGE_luci-app-dockerman=y
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

# Docker内核模块和依赖（如果启用Docker）
if [ "$ENABLE_DOCKER" = "y" ]; then
    cat >> .config <<EOF
# Docker核心
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_docker-compose=y

# Docker必需内核模块
CONFIG_PACKAGE_kmod-fs-overlay=y
CONFIG_PACKAGE_kmod-fuse=y
CONFIG_PACKAGE_kmod-dm=y
CONFIG_PACKAGE_kmod-br-netfilter=y
CONFIG_PACKAGE_kmod-ikconfig=y
CONFIG_PACKAGE_kmod-nf-conntrack-netlink=y
CONFIG_PACKAGE_kmod-nf-ipvs=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_kmod-ipt-extra=y
CONFIG_PACKAGE_kmod-ipt-ipset=y
CONFIG_PACKAGE_kmod-ipt-nat=y
CONFIG_PACKAGE_kmod-ipt-nat-extra=y
CONFIG_PACKAGE_kmod-ipt-nat6=y

# Cgroups支持
CONFIG_PACKAGE_kmod-crypto-user=y
CONFIG_PACKAGE_kmod-vxlan=y
CONFIG_PACKAGE_kmod-ip6-tunnel=y

# 网络支持
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-socket=y

# Docker存储驱动支持
CONFIG_PACKAGE_kmod-loop=y
CONFIG_PACKAGE_kmod-dax=y
CONFIG_PACKAGE_kmod-dm-raid=y
CONFIG_PACKAGE_kmod-dm-verity=y

# 可选：aufs作为备选存储驱动
CONFIG_PACKAGE_kmod-fs-aufs=y

# 文件系统支持
CONFIG_PACKAGE_kmod-fs-btrfs=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-vfat=y

# 容器工具
CONFIG_PACKAGE_containerd=y
CONFIG_PACKAGE_runc=y
CONFIG_PACKAGE_tini=y

# Docker CLI工具
CONFIG_PACKAGE_libnetwork=y
CONFIG_PACKAGE_libdevmapper=y

# 系统工具
CONFIG_PACKAGE_mount-utils=y
CONFIG_PACKAGE_losetup=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_f2fs-tools=y
CONFIG_PACKAGE_f2fsck=y
CONFIG_PACKAGE_resize2fs=y

# 网络工具
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_iptables-mod-ipopt=y
CONFIG_PACKAGE_iptables-mod-conntrack-extra=y
CONFIG_PACKAGE_ip6tables-mod-nat=y

# 进程和用户空间工具
CONFIG_PACKAGE_shadow-useradd=y
CONFIG_PACKAGE_shadow-groupadd=y
EOF
fi

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
echo "=== 第60-70行内容 ==="
sed -n '60,70p' .config

# 自动修复常见语法错误
sed -i 's/^\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+\([^=]\)/\1=\2/g' .config
sed -i 's/^[[:space:]]*#*[[:space:]]*\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+is not set/# \1 is not set/g' .config
sed -i '/^[[:space:]]*$/d' .config

echo "=== 修复后的第60-70行内容 ==="
sed -n '60,70p' .config
echo "=== 修复完成 ==="

# Docker编译验证
if [ "$ENABLE_DOCKER" = "y" ]; then
    echo "=== Docker编译配置验证 ==="
    echo "检查Docker相关配置..."
    
    # 检查.config中的Docker配置
    DOCKER_CONFIGS=$(grep -E "CONFIG_PACKAGE_(docker|dockerd|kmod-fs-overlay|containerd)" .config 2>/dev/null || true)
    
    if [ -n "$DOCKER_CONFIGS" ]; then
        echo "Docker配置已包含："
        echo "$DOCKER_CONFIGS" | head -20
    else
        echo "警告：未找到Docker相关配置，将自动添加..."
        # 自动添加Docker配置
        cat >> .config <<DOCKER_AUTO
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_kmod-fs-overlay=y
CONFIG_PACKAGE_containerd=y
DOCKER_AUTO
    fi
    
    # 检查内核配置
    if [ -f "target/linux/x86/config-$KERNEL_PATCHVER" ]; then
        echo "检查内核overlayfs支持..."
        grep -q "CONFIG_OVERLAY_FS" target/linux/x86/config-$KERNEL_PATCHVER && \
            echo "✓ overlayfs内核支持已配置" || \
            echo "⚠ overlayfs内核支持未找到"
    fi
    echo "=== Docker验证完成 ==="
fi

# 返回目录
cd $HOME
