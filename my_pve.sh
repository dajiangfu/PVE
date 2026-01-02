#!/bin/bash

# 注意：本脚本只针对 PVE9 编写，专用于 PVE9

# printfn 实现 printf+\n 的效果，也就是和 echo 效果一样，输出字符串后在后面自动输出 \n 换行符
# 比如 echo "$content" > "$cfg" 就可以写成 printfn "$content" > "$cfg"
# printfn() {
#   printf "%s\n" "$1"
# }
# blue() {
#   printf "\033[34m\033[01m%s\033[0m\n" "$1"
# }
# green() {
#   printf "\033[32m\033[01m%s\033[0m\n" "$1"
# }
# red() {
#   printf "\033[31m\033[01m%s\033[0m\n" "$1"
# }
# yellow() {
#   printf "\033[33m\033[01m%s\033[0m\n" "$1"
# }
# # 不换行输出写法，增加 -n
# yellow_n() {
#   printf "\033[33m\033[01m%s\033[0m" "$1"
# }

printfn() {
  local IFS=" "
  printf "%s\n" "$*"
}
blue() {
  local IFS=" "
  printf "\033[34m\033[01m%s\033[0m\n" "$*"
}
green() {
  local IFS=" "
  printf "\033[32m\033[01m%s\033[0m\n" "$*"
}
red() {
  local IFS=" "
  printf "\033[31m\033[01m%s\033[0m\n" "$*"
}
yellow() {
  local IFS=" "
  printf "\033[33m\033[01m%s\033[0m\n" "$*"
}
# 不换行输出写法，增加 -n
yellow_n() {
  local IFS=" "
  printf "\033[33m\033[01m%s\033[0m" "$*"
}

# 旋转动效函数
spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c] " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    # 根据图标长度退格 (\b)
    printf "\b\b\b\b\b"
  done
  # 任务结束后清空进度图标位置
  printf "    \b\b\b\b"
}

# 设置 web 登录页默认语言为简体中文
set_default_language_zh_CN() {
  local cfg="/etc/pve/datacenter.cfg"
  local content

  # 文件不存在：直接失败
  if [ ! -f "$cfg" ]; then
    red "错误：$cfg 不存在！"
    return 1
  fi

  # 已经是 zh_CN，直接返回（幂等）
  if grep -qE '^[[:space:]]*language:[[:space:]]*zh_CN' "$cfg"; then
    green "PVE 默认语言已是 zh_CN，无需修改"
    return 0
  fi

  # 修改或添加配置，使用内存变量处理，避免操作 pmxcfs 时产生过多的磁盘/集群同步动作
  if grep -q '^[[:space:]]*language:' "$cfg"; then
    # 已有 language 配置项，替换现有行
    content=$(sed 's/^[[:space:]]*language:.*/language: zh_CN/' "$cfg")
  else
    # 无 language 配置项，智能追加
    content=$(cat "$cfg")
    # 如果内容不为空且最后一个字符不是换行符，则补齐换行符
    if [[ -n "$content" && "${content: -1}" != $'\n' ]]; then
      content+=$'\n'
    fi
    content+="language: zh_CN"
  fi

  # 4. 回写文件 (保持原子性和权限)
  if printfn "$content" > "$cfg"; then
    green "PVE 默认语言已设置为 zh_CN（刷新 Web 即可生效）"
  else
    red "错误：无法写入 $cfg"
    return 1
  fi
}

# 删除 local_lvm
# PVE 安装好后的第一件事就是删除 local-lvm 分区
# PVE 系统在安装的时候默认会把储存划分为 local 和 local-lvm 两个块，在实际使用的时候往往其中一个不够用了另一个还很空的情况，可以删除 local-lvm 的空间，然后把全部分配给 local，方便自己管理
delete_local_lvm() {
  # 0. 确认 VG pve 存在
  if ! vgs pve >/dev/null 2>&1; then
    red "错误：未检测到 VG pve，终止操作"
    return 1
  fi

  # 1. 检查 pve/data 是否存在
  if ! lvs pve/data >/dev/null 2>&1; then
    blue "检测到 pve/data 不存在，local-lvm 可能已删除，跳过操作"
    return 0
  fi

  # 2. 删除逻辑卷
  if ! lvremove -y pve/data; then
    red "错误：无法删除 pve/data，请确保没有虚拟机/容器在使用"
    return 1
  fi
  green "底层逻辑卷 pve/data 已删除"

  # 3. 移除 PVE 存储配置
  # 执行此命令只会从 PVE 的配置文件（/etc/pve/storage.cfg）中移除该存储的挂载/定义，不会物理格式化硬盘，但会导致 PVE 界面上无法再看到和使用该存储
  pvesm remove local-lvm >/dev/null 2>&1
  green "PVE 存储配置 local-lvm 已移除"

  # 4. 扩展 root
  if ! lvextend -l +100%FREE -r pve/root; then
    red "错误：root 扩容失败"
    return 1
  fi
  green "Root 分区已成功扩展并自动调整文件系统大小"

  # 5. 设置 local 存储内容(因为后面要创建 yuan 目录存储所有内容，不用 local ，所以 local 内容设置默认即可，所以此项被注释)
  # pvesm set local --content backup,iso,vztmpl,rootdir,snippets >/dev/null 2>&1
  # green "已将所有功能开启到 local 存储中"

  green "local-lvm 已成功合并至 root"
}

# 取消无效订阅弹窗
delete_invalid_subscription_popup() {
  local jsfile="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  local bakjs="${jsfile}.bak"
  
  # 检查是否已经修改过
  if grep -q "void({ //Ext.Msg.show({" "$jsfile"; then
    green "订阅弹窗已修改过，无需重复操作"
    return 0
  fi
  
  # 备份原始文件，如果升级了，jsfile 会变回原样，我们需要重新备份
  cp "$jsfile" "$bakjs"
  
  # 修改取消弹窗
  # 匹配：包含 No valid subscription 的 Ext.Msg.show({
  # 将 Ext.Msg.show({ 替换为：void({ //Ext.Msg.show({
  yellow "正在修改 JS 文件以禁用订阅弹窗..."
  if sed -Ezi "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" "$jsfile"; then
    # 重启服务
    systemctl restart pveproxy.service
    green "订阅弹窗逻辑已禁用，如果 PVE 界面还有弹窗，记得按 Ctrl+F5 强制刷新，因为浏览器会缓存这个 JS 文件"
  else
    red "错误：JS 修改失败"
  fi
}

# PVE 软件源更换，建议尽可能使用官方源不是镜像源，如网络实在连不上官方源则使用第三方源
change_source() {
  local sources_file="/etc/apt/sources.list.d/debian.sources"
  local baksources="${sources_file}.bak"
  local proxmox_file="/etc/apt/sources.list.d/proxmox.sources"
  local bakproxmox="${proxmox_file}.bak"
  local choice="n"
  
  # PVE9 起删除旧的 .list 文件（如有）
  rm -f /etc/apt/sources.list >/dev/null 2>&1
  rm -f /etc/apt/sources.list.d/*.list >/dev/null 2>&1
  # 强烈建议先删除企业源和 ceph 源
  rm -f /etc/apt/sources.list.d/pve-enterprise.sources >/dev/null 2>&1
  rm -f /etc/apt/sources.list.d/ceph.sources >/dev/null 2>&1
  
  # 如果 debian.sources 不存在，自动恢复
  if [ ! -f "$sources_file" ]; then
    if [ ! -f "$baksources" ]; then
      yellow "检测到 debian.sources 已丢失且无备份，重新创建并写入官方基础源"
      cat > "$sources_file" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

EOF
      # 仅第一次创建基础源的备份，以锁定官方基础源的备份
      cp "$sources_file" "$baksources"
    else
      yellow "检测到 debian.sources 已丢失但有备份，从备份文件恢复"
      cp "$baksources" "$sources_file"
    fi
  else
    if grep -q "debian.org" "$sources_file" >/dev/null 2>&1; then
      green "当前正在使用官方基础源"
      # 仅第一次创建基础源的备份，以锁定官方基础源的备份
      if [ ! -f "$baksources" ]; then
        cp "$sources_file" "$baksources"
      fi
    else
      yellow "当前正在使用镜像基础源"
    fi
  fi
  
  # 配置免订阅存储库 pve-no-subscription
  # 如果 proxmox_file.sources 不存在，自动恢复
  if [ ! -f "$proxmox_file" ]; then
    if [ ! -f "$bakproxmox" ]; then
      yellow "检测到 proxmox.sources 已丢失且无备份，重新创建并写入官方免订阅源"
      cat > "$proxmox_file" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      # 仅第一次创建免订阅源的备份，以锁定官方免订阅源的备份
      cp "$proxmox_file" "$bakproxmox"
    else
      yellow "检测到 proxmox.sources 已丢失但有备份，从备份文件恢复"
      cp "$bakproxmox" "$proxmox_file"
    fi
  else
    if grep -q "download.proxmox.com" "$proxmox_file" >/dev/null 2>&1; then
      green "当前正在使用官方免订阅源"
      # 仅第一次创建免订阅源的备份，以锁定官方免订阅源的备份
      if [ ! -f "$bakproxmox" ]; then
        cp "$proxmox_file" "$bakproxmox"
      fi
    else
      yellow "当前正在使用镜像免订阅源"
    fi
  fi
  
  yellow "准备替换 $sources_file 和 $proxmox_file 中的内容..."
  green "请选择要使用的 PVE 源版本："
  green "0) 官方源，本系统默认官方源，需网络支持"
  green "1) 镜像源，国内用户，网络访问受限者选择"
  read -p "请输入数字 (0 或 1): " choice
  case "$choice" in
    0)
      green "使用官方源..."
      if [ -f "$baksources" ]; then
        cp "$baksources" "$sources_file"
        green "已恢复官方 debian.sources"
      else
        yellow "未找到备份文件，保持当前 debian.sources 不变"
      fi
      if [ -f "$bakproxmox" ]; then
        cp "$bakproxmox" "$proxmox_file"
        green "已恢复官方 proxmox.sources"
      else
        yellow "未找到备份文件，保持当前 proxmox.sources 不变"
      fi
      ;;
    1)
      green "使用中科大镜像源..."
      # Types: deb 软件包，Types: deb-src 源码包,用于源码下载自行编译场景，去掉源码 deb-src 包可提升 apt-get update 速度，下载更少索引文件
      cat > "$sources_file" <<'EOF'
# Types: deb deb-src
Types: deb
URIs: https://mirrors.ustc.edu.cn/debian
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# Types: deb deb-src
Types: deb
URIs: https://mirrors.ustc.edu.cn/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
      cat > "$proxmox_file" <<'EOF'
Types: deb
URIs: https://mirrors.ustc.edu.cn/proxmox/debian
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      ;;
    *)
      red "输入错误，退出！"
      return 1
      ;;
  esac

  green "替换完成！"
}

# 更新系统后执行系统清理程序，包含清理旧内核，只保留当前使用的和备用最新的这两个内核
# Jordan Hillis 的 pvekclean脚本的精华浓缩版
cleanup_pve() {
  local current_k=$(uname -r)
  local boot_free_before=$(df -m / | awk 'NR==2 {print $4}') # 获取当前根分区剩余空间 (MB)
  local boot_free_after=0
  local saved_space=0
  local k_list=""
  local to_remove=""
  local count=0
  local confirm=""
  local pkg=""
  
  yellow "启动系统深度维护程序..."
  
  # 1. APT 缓存瘦身
  green "清理 APT 下载缓存..."
  apt-get autoclean -y >/dev/null 2>&1
  apt-get clean -y >/dev/null 2>&1
  
  # 2. 内核精准净化 (兼容 PVE 7/8/9)
  green "检索冗余内核..."
  # 匹配 pve-kernel (旧) 和 proxmox-kernel (新)
  k_list=$(dpkg-query -W -f='${Package}\n' | grep -E "^(pve|proxmox)-kernel-[0-9]" | grep -vE "series|transitional|$current_k" | sort -V)
  if [ -n "$k_list" ] && [ $(echo "$k_list" | wc -l) -gt 1 ]; then
    # 核心逻辑：保留列表最后一个（最新版），剩下的全部加入删除清单
    to_remove=$(echo "$k_list" | head -n -1)
    count=$(echo "$to_remove" | wc -l)
    yellow "发现 $count 个可清理内核。将保留当前运行核($current_k)及一个备份核。"
    echo "$to_remove" | sed 's/^/  [待卸载] /'
    read -p "确认执行深度卸载并刷新引导？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      for pkg in $to_remove; do
        green "正在净化: $pkg"
        apt-get purge -y "$pkg" >/dev/null 2>&1
      done
      green "正在更新 GRUB 引导菜单..."
      update-grub >/dev/null 2>&1
      green "内核卸载及 GRUB 刷新完成"
    else
      green "已跳过内核卸载步骤"
    fi
  else
    green "内核环境已是精简状态，无需处理"
  fi
  
  # 3. 彻底清理孤立的依赖（包含 Headers）
  green "清理残留头文件与孤立依赖..."
  apt-get autoremove --purge -y >/dev/null 2>&1
  
  # 4. 统计
  boot_free_after=$(df -m / | awk 'NR==2 {print $4}')
  saved_space=$((boot_free_after - boot_free_before))
  if [ "$saved_space" -gt 0 ]; then
    green "清理完毕！共释放空间: ${saved_space}MB"
  else
    green "系统已处于最佳状态，未发现可清理的冗余文件。"
  fi
}
# cleanup_pve() {
#   # 清理本地缓存中过期的 .deb 包（存放在 /var/cache/apt/archives）
#   green "清理 APT 缓存..."
#   apt-get autoclean
#   # 检查系统中不再被任何已安装软件依赖的包
#   green "以下包将被移除（不包含当前内核）："
#   apt-get autoremove --purge --dry-run | grep -v "$(uname -r)"
#   # 执行清理
#   yellow "开始执行系统清理..."
#   apt-get autoremove --purge -y
# }

# 更新 pve 系统
update_pve() {
  local choice="n"
  if ! apt-get update -q; then
    red "存储库更新失败，请检查网络或 debian.sources 配置或订阅密钥状态！"
    return 1
  fi

  green "升级软件包..."
  if ! apt-get full-upgrade -y; then
    red "软件包升级失败，请检查错误日志！"
    return 1
  fi
  
  # 更新系统后执行系统清理程序，包含清理旧内核，只保留当前使用的和备用最新的这两个内核
  cleanup_pve
  green "可在重启后再次运行更新系统后执行系统清理程序"
  
  # 询问用户是否重启
  read -p "已更新完毕，是否重启系统？请输入 [Y/n]: " choice
  choice=$(printf "$choice" | tr 'A-Z' 'a-z')  # 转换为小写，兼容性好，也可以用更现代的choice=${choice,,}
  [ -z "${choice}" ] && choice="y"
  if [[ "$choice" == "y" ]]; then
    green "系统将在 2 秒后重启..."
    sleep 2
    sync
    reboot
  else
    blue "已取消，请稍后自行重启。"
  fi
}

# 开启 intel 核显 SR-IOV 虚拟化直通
install_intel_sr_iov_dkms() {
  local choice="n"
  local VERSION=""
  local repo_url="https://github.com/strongtz/i915-sriov-dkms.git"
  local modules=""
  local m=""
  local vga_id=""
  local sysfs_line=""
  
  apt-get update -q && apt-get install -y git sysfsutils pve-headers mokutil build-essential dkms
  
  VERSION=$(dkms status i915-sriov-dkms | awk -F'[,/:]' '{print $2}' | tr -d '[:space:]' | sort -u)
  # VERSION 检查变量是否为空
  if [ -n "$VERSION" ]; then
    # 循环遍历并删除
    printfn "$VERSION" | while read -r v; do
      [ -z "$v" ] && continue  # 跳过空行
      yellow "正在彻底移除 i915-sriov-dkms 版本: $v ..."
      dkms remove -m i915-sriov-dkms -v "$v" --all
    done
    green "所有已记录的 DKMS 版本已清理完毕。"
  else
    blue "未发现任何已安装的 i915-sriov-dkms 版本，跳过移除步骤。"
  fi
  # find /lib/modules -regex ".*/updates/dkms/i915.ko" -delete # 删除模块文件 (.ko)
  # 手动 find -delete 删除了 .ko 文件，内核的 modules.dep 索引里可能还残留着该模块的信息，导致系统在启动时尝试加载一个不存在的文件而报 Error
  rm -rf /usr/src/i915-sriov-dkms-* # 清理源码目录
  rm -rf /var/lib/dkms/i915-sriov-dkms # 清理数据库残留
  rm -rf ~/i915-sriov-dkms* # 清理用户目录下的克隆代码
  
  # 克隆 DKMS repo 并做一些构建工作
  cd ~
  git clone "$repo_url"
  # apt-get install build-* dkms
  # build-* 是 通配符匹配，它会安装所有以 build- 开头的包，这可能包括大量不必要的软件。
  # build-* 并不是一个官方推荐的安装方式，它可能会匹配到 大量不相关的软件
  # 不推荐 直接使用 build-*，因为它可能会安装许多你 不需要的构建工具，导致系统安装冗余包
  # 不建议使用 build-*，可能会安装不相关的包，占用磁盘空间并影响系统稳定性
  cd ~/i915-sriov-dkms
  # 从 dkms.conf 文件中自动提取版本号
  VERSION=$(grep "PACKAGE_VERSION=" dkms.conf | sed -E 's/.*="([^"]+)".*/\1/')
  # 将源码同步到系统标准位置，确保长期稳定
  mkdir -p /usr/src/i915-sriov-dkms-"$VERSION"
  cp -rf . /usr/src/i915-sriov-dkms-"$VERSION"
  chown -R root:root /usr/src/i915-sriov-dkms-"$VERSION"
  chmod -R 755 /usr/src/i915-sriov-dkms-"$VERSION"
  green "正在添加 DKMS 源码..."
  # 将原来的 dkms add . 替换为显式指定 dkms add -m i915-sriov-dkms -v "$VERSION"
  if ! dkms add -m i915-sriov-dkms -v "$VERSION"; then
    red "DKMS 添加失败，退出！"
    return 1
  fi
  
  # 构建新内核并检查状态。验证它是否显示已安装
  green "正在为内核 $(uname -r) 编译并安装驱动..."
  if ! dkms install -m i915-sriov-dkms -v "$VERSION" -k "$(uname -r)" --force; then
    red "DKMS 安装失败！请检查以下内容："
    red "1. 是否已安装 build-essential 和 dkms"
    red "2. 是否有足够的磁盘空间"
    red "3. 运行 dkms status 确保模块被正确识别"
    return 1
  fi
  # 运行 dkms status 并检查i915-sriov-dkms是否已安装"
  if dkms status -m i915-sriov-dkms | grep -iqE ":\s+installed"; then
    green "i915-sriov-dkms已安装，继续..."
  else
    red "i915-sriov-dkms未安装，退出！"
    return 1
  fi

  # 对于全新安装的 Proxmox 8.1 及更高版本，可以启用安全启动。以防万一，我们需要加载 DKMS 密钥，以便内核加载模块。
  # 运行以下命令，然后输入密码。此密码仅用于 MOK 设置，重新启动主机时将再次使用。此后，不需要密码。
  # 它不需要与您用于 root 帐户的密码相同。
  green "即将导入 MOK 密钥。请注意："
  yellow "1. 请输入一个临时密码（至少8位）。"
  yellow "2. 在PVE重启时的显示器启动界面依次选择Enroll MOK--->Continue--->Yes--->password(输入之前设置的MOK密码回车)--->Reboot"
  mokutil --import /var/lib/dkms/mok.pub
  
  # Proxmox GRUB 配置，Proxmox 的默认安装使用 GRUB 引导加载程序
  # module_blacklist=xe 是黑名单 xe 驱动，避免系统自动切换为 xe 驱动，i915 驱动更成熟，且 istoreos 中也是 i915 驱动
  # initcall_blacklist=sysfb_init 是禁用 framebuffer 初始化，宿主机无法显示 HDMI/DP 图形界面，有利于 VM 中通过 HDMI/DP 显示画面，我的 PVE 系统本身不需要用显示器接口看画面，只在 VM 中使用显卡，可以加
  cp -a /etc/default/grub{,.bak}
  sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=3 module_blacklist=xe initcall_blacklist=sysfb_init"' /etc/default/grub
  
  # 加载内核模块:
  # printfn -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" >> /etc/modules # 此命令会造成重复追加，废除
  modules=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")
  for m in "${modules[@]}"; do
      grep -qxF "$m" /etc/modules || printfn "$m" >> /etc/modules
  done

  # 完成 PCI 配置
  # 现在我们需要找到 VGA 卡位于哪个 PCIe 总线上。通常 VGA 总线 ID 为 00:02.0
  # 获取 VGA 设备的 PCIe 总线号
  # vga_id=$(lspci | grep VGA | awk '{print $1}') # 此命令会造成多个 vga_id 被赋值到一起
  vga_id=$(lspci | grep VGA | awk '{print $1}' | head -n1) # 取第一行物理 GPU 的 vga_id，因为物理 GPU 的vga_id 是 .0 地址总是在最前面，VF 的 vga_id 是从 .1 开始的

  #确保成功获取 vga_id
  if [ -z "$vga_id" ]; then
    red "未找到 VGA 设备，请检查 lspci 输出！"
    return 1
  fi

  # 生成 sysfs 配置
  # printfn "devices/pci0000:00/0000:$vga_id/sriov_numvfs = 3" > /etc/sysfs.conf # 此命令会造成重复追加，废除
  # sysfs_line="devices/pci0000:00/0000:$vga_id/sriov_numvfs = 3"
  local full_path=$(find /sys/devices/pci* -name "*$vga_id" -type d | head -n 1 | sed 's|/sys/||')
  sysfs_line="$full_path/sriov_numvfs = 3"
  touch /etc/sysfs.conf
  grep -qxF "$sysfs_line" /etc/sysfs.conf || printfn "$sysfs_line" >> /etc/sysfs.conf
  systemctl enable sysfsutils

  # 输出结果
  printfn "已写入 /etc/sysfs.conf，内容如下："
  # 匹配丢弃所有以 # 开头的行。这样就过滤掉所有注释行和空白行，只显示文件中“真正有效”的内容
  grep -v '^#' /etc/sysfs.conf | grep -v '^$'
  # cat /etc/sysfs.conf # cat 该文件显示里面所有内容，如果你想看到注释内容可以用这条命令
  
  # 应用修改
  update-grub
  update-initramfs -u -k all
  
  # 重启 Proxmox 主机。如果使用 Proxmox 8.1 或更高版本并启用安全启动，则必须设置 MOK。
  # 在 Proxmox 主机重启时，监控启动过程并等待执行 MOK 管理窗口（下面的屏幕截图）。
  # 如果错过了第一次重启，则需要重新运行 mokutil 命令并再次重启。DKMS 模块将不会加载，直到您完成此设置
  # 在PVE重启时的显示器启动界面依次选择 Enroll MOK--->Continue--->Yes--->password (输入之前设置的MOK密码回车) --->Reboot
  # 硬件里面添加 PCI 设备可选择虚拟出来的几个 SR-IOV 核显，注意要记得勾选主 GPU 和 PCI-Express，显示设置为 VirtlO-GPU，这样控制台才有画面
  # 询问用户是否重启
  read -p "已设置完毕，是否重启系统？请输入 [Y/n]: " choice
  choice=$(printf "$choice" | tr 'A-Z' 'a-z')  # 转换为小写，兼容性好，也可以用更现代的choice=${choice,,}
  [ -z "${choice}" ] && choice="y"
  if [[ "$choice" == "y" ]]; then
    green "系统将在 2 秒后重启..."
    sleep 2
    sync
    reboot
  else
    blue "已取消，请稍后自行重启。"
  fi
}

# 安装 UPS 监控软件 NUT
install_ups_nut() {
  local BASE_URL=""
  local DEST_DIR=""
  local FILES=""
  local FILE=""
  local UPSD_USERS_FILE="/etc/nut/upsd.users"
  local UPSMON_CONF_FILE="/etc/nut/upsmon.conf"
  # 新/旧用户名和密码
  local OLD_USERNAME="monusername"
  local OLD_PASSWORD="mima"
  local NEW_USERNAME="monusername"
  local NEW_PASSWORD="mima"
  local ESCAPED_NEW_USERNAME=""
  local ESCAPED_NEW_PASSWORD=""
  
  apt-get update -q
  apt-get install -y nut # nut 包通常会安装一些常见的依赖包，如 nut-client、nut-server、nut-cgi、nut-scanner，因此你可能不需要手动安装这些组件。
  # 查看 UPS 设备硬件信息
  # nut-scanner # 需要用户交互，在扫描过程中可能会提示用户做出选择，这个命令用于扫描计算机上连接的 UPS 设备，检查系统是否能够识别和通信，它会尝试自动检测并列出所有可用的 UPS 设备。
  nut-scanner -U # -U 选项用于使扫描器以 "不带用户交互" 的方式运行，会自动执行扫描，不会要求用户输入任何内容，适合自动化操作。
  green "安装NUT完成！下面进行配置"
  # GitHub 文件路径
  BASE_URL="https://raw.githubusercontent.com/dajiangfu/PVE/main/nut"
  
  # 目标目录
  DEST_DIR="/etc/nut"
  
  # 文件列表
  FILES=("nut.conf" "ups.conf" "upsd.conf" "upsd.users" "upsmon.conf" "upssched.conf" "upssched-cmd")
  
  # 确保目标目录存在
  if [ ! -d "$DEST_DIR" ]; then
    blue "目录 $DEST_DIR 不存在，开始创建..."
    mkdir -p "$DEST_DIR"
  fi
  
  # 下载文件并保存到 /etc/nut 目录
  for FILE in "${FILES[@]}"; do
    green "下载 $FILE..."
    curl -fsSL -o "$DEST_DIR/$FILE" "$BASE_URL/$FILE" || {
      red "$FILE 下载失败"
      return 1
    }
  done
  green "所有文件已下载并保存到 $DEST_DIR."
  
  # 提示用户输入新的用户名和密码，如果用户直接按回车（什么都不输入），变量就会自动被赋值为默认值
  read -p "请输入新的 NUT 监控用户名 [默认: monusername]: " NEW_USERNAME
  # 如果输入为空，设置默认值并给用户提示
  if [ -z "$NEW_USERNAME" ]; then
    NEW_USERNAME="monusername"
    yellow "-> 检测到空输入，已自动应用默认用户名: monusername"
  else
    green "-> 用户名已自定义。"
  fi
  read -sp "请输入新的密码 [默认: mima]: " NEW_PASSWORD
  printfn ""
  # 如果输入为空，设置默认值并给用户提示
  if [ -z "$NEW_PASSWORD" ]; then
    NEW_PASSWORD="mima"
    yellow "-> 检测到空输入，已自动应用默认密码: mima"
  else
    green "-> 密码已自定义。"
  fi
  
  # 备份原始文件
  cp "$UPSD_USERS_FILE" "$UPSD_USERS_FILE.bak"
  cp "$UPSMON_CONF_FILE" "$UPSMON_CONF_FILE.bak"
  
  # 对用户名和密码进行转义，避免特殊字符导致 sed 出错
  ESCAPED_NEW_USERNAME=$(printf '%s\n' "$NEW_USERNAME" | sed 's/[\/&]/\\&/g')
  ESCAPED_NEW_PASSWORD=$(printf '%s\n' "$NEW_PASSWORD" | sed 's/[\/&]/\\&/g')
  # 使用 sed 替换用户名和密码
  sed -i "s#$OLD_USERNAME#$ESCAPED_NEW_USERNAME#g" "$UPSD_USERS_FILE" "$UPSMON_CONF_FILE"
  sed -i "s#$OLD_PASSWORD#$ESCAPED_NEW_PASSWORD#g" "$UPSD_USERS_FILE" "$UPSMON_CONF_FILE"
  
  green "正在优化配置文件权限..."
  # 1. 设置所有权：root 拥有，nut 组可读
  chown root:nut /etc/nut/*
  
  # 2. 设置普通配置文件：640 (属主读写，组只读，其他无权)
  # 这样 nut 用户可以读取配置，但不能修改，也不能被无关人员查看
  chmod 640 /etc/nut/*.conf
  chmod 640 /etc/nut/upsd.users
  
  # 3. 设置脚本文件：750 (属主读写执行，组读执行，其他无权)
  # 只有这个文件需要执行权限，以便触发关机动作
  chmod 750 /etc/nut/upssched-cmd
  
  green "配置更新完成！重启服务..."
  systemctl restart nut-server
  sleep 3 # 给驱动一点初始化时间
  systemctl restart nut-monitor
  systemctl restart nut-upssched
  
  # 检查服务状态
  if systemctl is-active --quiet nut-server nut-monitor; then
    green "NUT 服务已启动！"
  else
    red "NUT 服务启动失败，请检查 /etc/nut/ups.conf 中的驱动配置。"
  fi
  upsc tgbox850@localhost
}

# 禁用 KSM
close_ksm() {
  local services=""
  local svc=""
  local ksm_status=""
  
  green "正在禁用 KSM (内核内存共享)..."
  # 1. 禁用服务层（ksmtuned 是 PVE 自动调节 KSM 的守护进程）
  services=("ksmtuned" "ksm")
  for svc in "${services[@]}"; do
    if systemctl list-unit-files | grep -q "^$svc.service"; then
      systemctl disable --now "$svc" >/dev/null 2>&1
    fi
  done

  # 2. 内核层禁用
  # 停止 KSM 扫描
  printf 0 > /sys/kernel/mm/ksm/run
  # 将扫描页数设为 0 以节省微量 CPU
  printf 0 > /sys/kernel/mm/ksm/pages_to_scan

  # 3. 验证状态
  ksm_status=$(cat /sys/kernel/mm/ksm/run)
  if [ "$ksm_status" -eq 0 ]; then
    green "KSM 已成功禁用 (当前内核状态: $ksm_status)"
  else
    # 状态 2 代表正在进行 Unmerge（拆分页面）
    if [ "$ksm_status" -eq 2 ]; then
       yellow "KSM 正在释放已合并的内存，请稍后再次检查..."
    else
       red "KSM 禁用失败，当前状态: $ksm_status"
    fi
  fi
}

# 更新 CPU 微码
update_microcode() {
  local cpu_vendor=$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo)
  local mc_package=""
  local current_mc=""
  local package_ver=""
  local candidate_ver=""
  
  # 检测 CPU 类型
  if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
    mc_package="intel-microcode"
    green "检测到 Intel CPU，准备更新微码..."
  elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
    mc_package="amd64-microcode"
    green "检测到 AMD CPU，准备更新微码..."
  else
    red "未识别的 CPU 类型，跳过微码更新。"
    return 1
  fi
  
  # 获取当前运行的微码版本
  current_mc=$(grep microcode /proc/cpuinfo | awk '{print $3}' | head -n1)
  green "当前运行中的微码版本: $current_mc"
  
  # 检查包是否已安装
  if dpkg -s "$mc_package" >/dev/null 2>&1; then
    package_ver=$(dpkg -s "$mc_package" | awk '/Version:/{print $2}')
    candidate_ver=$(apt-cache policy "$mc_package" | awk '/Candidate:/{print $2}')
    green "$mc_package 已安装，包版本: $package_ver，候选版本: $candidate_ver"
    # 判断是否需要升级
    if dpkg --compare-versions "$package_ver" lt "$candidate_ver"; then
      yellow "检测到微码包有新版本，准备升级..."
      # 更新仓库索引
      apt-get update -q
      if apt-get install --only-upgrade -y "$mc_package"; then
        green "微码包升级成功"
      else
        red "微码包安装或更新失败，请检查网络或 APT 状态。"
        return 1
      fi
    else
      green "微码包已是最新版本，无需升级。"
      return 0
    fi
  else
    yellow "微码包未安装，准备安装 $mc_package..."
    # 更新仓库索引
    apt-get update -q
    if apt-get install -y "$mc_package"; then
      green "微码包升级成功"
    else
      red "微码包安装或更新失败，请检查网络或 APT 状态。"
      return 1
    fi
  fi
  
  # 获取升级后的 CPU 微码版本（未重启前可能不会变化）
  current_mc=$(grep microcode /proc/cpuinfo | awk '{print $3}' | head -n1)
  green "升级后的微码版本: $current_mc (需重启刷新版本号)"
  yellow "提示：必须【重启物理机】才能将新微码加载进 CPU 硬件。"
}

# THP（Transparent Huge Pages）设置为 madvise 智能模式，对不需要的程序默认关闭，对需要的程序开启
# 通常 PVE9 安装后 THP 默认已经是 madvise 智能模式
set_thp_madvise() {
  local thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
  local thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"
  local current_thp=""
  local current_defrag=""
  local sysfs_line=""
  
  # 1. 检查 THP 是否存在
  if [ ! -f "$thp_enabled" ] || [ ! -f "$thp_defrag" ]; then
    red "当前内核不支持 THP，跳过配置。"
    return 1
  fi
  current_thp=$(cat "$thp_enabled")
  current_defrag=$(cat "$thp_defrag")
  printfn "当前 enabled 状态: $current_thp"
  printfn "当前 defrag 状态: $current_defrag"
  if [[ "$current_thp" =~ \[madvise\] && "$current_defrag" =~ \[madvise\] ]]; then
    green "THP 及其碎片整理 (Defrag) 已全部锁定为 madvise 模式，无需重复设置"
    return 0
  fi
  
  # 2. 创建持久化服务
  apt-get update -q && apt-get install -y sysfsutils
  yellow "正在通过 sysfsutils 配置 THP madvise..."
  sysfs_line="kernel/mm/transparent_hugepage/enabled = madvise"
  grep -qxF "$sysfs_line" /etc/sysfs.conf || printfn "$sysfs_line" >> /etc/sysfs.conf
  sysfs_line="kernel/mm/transparent_hugepage/defrag = madvise"
  grep -qxF "$sysfs_line" /etc/sysfs.conf || printfn "$sysfs_line" >> /etc/sysfs.conf
  systemctl enable sysfsutils
  green "sysfsutils 配置 THP madvise并启用成功"
  # 输出结果
  printfn "已写入 /etc/sysfs.conf，内容如下："
  # 匹配丢弃所有以 # 开头的行。这样就过滤掉所有注释行和空白行，只显示文件中“真正有效”的内容
  grep -v '^#' /etc/sysfs.conf | grep -v '^$'
  # cat /etc/sysfs.conf # cat 该文件显示里面所有内容，如果你想看到注释内容可以用这条命令
  
  # 3. 显示当前状态
  current_thp=$(cat "$thp_enabled")
  current_defrag=$(cat "$thp_defrag")
  printfn "当前 enabled 状态: $current_thp"
  printfn "当前 defrag 状态: $current_defrag"
  
  if [[ "$current_thp" =~ \[madvise\] && "$current_defrag" =~ \[madvise\] ]]; then
    green "THP 及其碎片整理 (Defrag) 已全部锁定为 madvise 模式(持久化已开启)"
  else
    red "THP 设置未生效，请检查系统状态"
  fi
}

# 改变 swappiness 值，保证物理内存充分使用，减少 swap
change_swa() {
  local current_swp=$(cat /proc/sys/vm/swappiness)
  local target_swp=10  # 建议设为 10，这是更具性能导向的 PVE 常用值
  local conf_file="/etc/sysctl.d/99-pve-swappiness.conf"
  
  printfn "当前 swappiness: $current_swp"
  if [ "$current_swp" -le 20 ]; then
    green "swappiness 配置合理（适合 PVE 宿主机）"
    return 0
  fi
  
  yellow "swappiness 偏高，调整为 $target_swp"
  
  # 立即修改内核运行参数
  if sysctl -w vm.swappiness="$target_swp" >/dev/null 2>&1; then
    green "内核 swappiness 已调整为 $target_swp"
  else
    red "内核 swappiness 调整失败"
  fi
  
  # 持久化到配置文件
  if printfn "vm.swappiness = $target_swp" > "$conf_file"; then
    if sysctl -p "$conf_file" >/dev/null 2>&1; then
      green "swappiness 持久化成功"
    else
      red "swappiness 持久化失败，请手动检查 $conf_file"
    fi
  else
    red "无法写入配置文件 $conf_file ，请检查磁盘空间或权限"
  fi
  
  # 验证
  current_swp=$(cat /proc/sys/vm/swappiness)
  if [ "$current_swp" -eq "$target_swp" ]; then
    green "swappiness 已成功调整为 $current_swp 并已持久化。"
  else
    red "swappiness 调整失败，请手动检查系统设置。"
    yellow "最终 swappiness: $current_swp"
  fi
}

# PVE9 宿主机开启 SSD TRIM 优化（针对 ext4/LVM 等文件系统）
# 通常 PVE9 安装后固态硬盘已经开启了 TRIM
enable_ssd_trim() {
  local start_time=""
  local end_time=""
  local log_file=""
  local trim_pid=""
  local exit_code=""
  local duration=""
  
  # 1. 检测是否存在非机械硬盘设备
  if lsblk -d -o ROTA | grep -q "0"; then
    green "检测到 SSD 存储设备，正在配置 fstrim..."
  else
    yellow "未检测到 SSD 存储，跳过 TRIM 配置。"
    return 0
  fi
  
  # 2. 检查并启用 fstrim.timer (持久化 + 立即启动)
  if systemctl is-active --quiet fstrim.timer >/dev/null 2>&1 && systemctl is-enabled --quiet fstrim.timer >/dev/null 2>&1; then
    green "SSD TRIM 定时维护已启用并在运行中，无需修改。"
  else
    yellow "检测到 TRIM 定时器未运行，正在激活..."
    systemctl enable fstrim.timer >/dev/null 2>&1
    if systemctl restart fstrim.timer >/dev/null 2>&1; then
      green "fstrim.timer 已成功激活并锁定开机自启。"
    else
      red "fstrim.timer 激活失败，请检查系统日志。"
      # 如果这里失败了，没必要进行后续的物理回收，直接返回
      return 1
    fi
  fi
  
  # 3. 立即执行一次物理 TRIM 回收（带旋转动效）
  # -a: 所有挂载点, -v: 显示详细回收了多少空间
  yellow "正在执行即时空间回收 (fstrim -av) 这可能需要几十秒，请稍候..."
  start_time=$(date +%s)
  log_file="/tmp/fstrim_result.log"
  # 将 fstrim 放到后台运行
  fstrim -av > "$log_file" 2>&1 &
  trim_pid=$!
  
  # 调用动效函数，传入 fstrim 的进程 ID
  spinner "$trim_pid"
  
  # 任务完成后获取结果
  wait "$trim_pid"
  exit_code=$?
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  
  if [ "$exit_code" -eq 0 ]; then
    cat "$log_file" | while read -r line; do
      green "  -> $line";
    done
    green "空间回收完成，总耗时: ${duration}s"
  else
    red "手动 TRIM 失败，请确认底层存储是否支持 discard"
    cat "$log_file"
  fi
  
  rm -f "$log_file"
}

# 设置 CPU governor 为 performance 模式（开机自启）
# 通常 PVE9 安装后所有 CPU 模式默认已经是 performance
set_cpu_performance() {
  local governor="performance"
  local cpu_dir="/sys/devices/system/cpu"
  local cpu_path=""
  local current_gov=""
  local need_change=false
  local sysfs_line=""
  local core_name=""
  
  # 0. 检测是否已经全部是 $governor
  # 使用 sort -V 处理 i5-13500 的 20 个核心排序，按照 0-19 而不是 0 1 10 11...19 2...9 这样
  # for cpu_path in $(ls -d "$cpu_dir"/cpu[0-9]* 2>/dev/null | sort -V); do
  for cpu_path in $(find "$cpu_dir" -maxdepth 1 -name "cpu[0-9]*" | sort -V); do
    if [ -f "$cpu_path/cpufreq/scaling_governor" ]; then
      current_gov=$(cat "$cpu_path/cpufreq/scaling_governor" 2>/dev/null)
      if [ "$current_gov" != "$governor" ]; then
        need_change=true
        break
      fi
    fi
  done
    
  if [ "$need_change" = false ]; then
    green "所有 CPU governor 已是 $governor，跳过设置"
    return 0
  fi
  
  # 1. 创建持久化服务
  apt-get update -q && apt-get install -y sysfsutils
  yellow "正在通过 sysfsutils 配置 CPU 为 $governor 模式..."
  for cpu_path in $(find "$cpu_dir" -maxdepth 1 -name "cpu[0-9]*" | sort -V); do
    if [ -f "$cpu_path/cpufreq/scaling_governor" ]; then
      core_name=$(basename "$cpu_path")
      sysfs_line="devices/system/cpu/$core_name/cpufreq/scaling_governor = $governor"
      # 检查并追加
      grep -qxF "$sysfs_line" /etc/sysfs.conf || printfn "$sysfs_line" >> /etc/sysfs.conf
    fi
  done
  systemctl enable sysfsutils
  green "sysfsutils 配置 CPU 为 $governor 模式并启用成功"
  # 输出结果
  printfn "已写入 /etc/sysfs.conf，内容如下："
  # 匹配丢弃所有以 # 开头的行。这样就过滤掉所有注释行和空白行，只显示文件中“真正有效”的内容
  grep -v '^#' /etc/sysfs.conf | grep -v '^$'
  # cat /etc/sysfs.conf # cat 该文件显示里面所有内容，如果你想看到注释内容可以用这条命令
  
  # 2. 显示状态
  printfn "当前 CPU governor 状态:"
  # cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor
  for cpu_path in $(find "$cpu_dir" -maxdepth 1 -name "cpu[0-9]*" | sort -V); do
    if [ -f "$cpu_path/cpufreq/scaling_governor" ]; then
      # 使用 basename 提取 cpu0, cpu1 等字样
      printfn "  $(basename "$cpu_path"): $(cat "$cpu_path/cpufreq/scaling_governor")"
    fi
  done
}

# PVE 常用优化，一键执行多项
Kernel_opt() {
  close_ksm
  update_microcode
  set_thp_madvise
  change_swa
  enable_ssd_trim
  set_cpu_performance
}

# 安装 GLANCES 硬件监控服务
install_glances_venv(){
  local PVE_IP=""
  # 设置Glances安装目录
  # GLANCES_DIR="/opt/glances"  # 调用使用$GLANCES_DIR

  # 安装 Python 和 venv
  green "安装Python及venv..."
  apt-get update -q
  apt-get install -y python3 python3-pip python3-venv lm-sensors

  # 创建 venv
  green "创建Python虚拟环境..."
  python3 -m venv /opt/glances

  # 激活 venv 并安装 Glances，激活 venv 后使用 pip 安装软件不会影响 PVE 系统所有安装的 Python 包都只会存放在 /opt/glances 目录，不会污染系统
  green "进入虚拟环境并安装Glances..."
  source /opt/glances/bin/activate
  pip install --upgrade pip
  pip install glances
  pip install fastapi
  pip install uvicorn
  pip install jinja2
  # 退出 venv，退出 venv 后，pip 重新指向系统 Python，你的 venv 仍然保留，但不会影响其他操作。
  deactivate
  
  # 软链接Glances让其全局可用
  # green "添加Glances到全局路径..."
  # ln -sf /opt/glances/bin/glances /usr/local/bin/glances
  # 如使用 glances -w --username --password 命令创建用户名和密码是要用到，不然 glances 命令无法识别

  # 创建 systemd 服务文件
  green "创建 systemd 服务..."
cat << EOF > /etc/systemd/system/glances.service
[Unit]
Description=Glances Monitoring Service
After=network.target

[Service]
ExecStart=/opt/glances/bin/glances -w
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  # 重新加载 systemd 并启动 Glances
  green "启动Glances..."
  systemctl daemon-reload
  systemctl enable glances.service
  systemctl restart glances.service
  # systemctl enable --now glances.service
  # systemctl enable --now glances.service的作用
  # 这个命令等同于两步操作：
  # systemctl enable glances.service   # 设置开机自启
  # systemctl restart glances.service    # 立即启动服务
  # --now 选项表示同时启用（开机自启）并立即启动该服务。

  # 获取PVEIP地址
  PVE_IP=$(hostname -I | awk '{print $1}')

  green "Glances安装完成！"
  green "现在可以在HomeAssistant添加Glances监控PVE！"
  green "WebUI和API访问地址: http://$PVE_IP:61208"
  systemctl status glances.service
  # 如果以后不再需要 Glances 或其他 Python 软件，直接删除 venv 目录即可：
  # systemctl stop glances.service
  # systemctl disable glances.service
  # rm -f /etc/systemd/system/glances.service
  # rm -f /usr/local/bin/glances  #如果之前创建过glances命令的软链接，需要删除
  # rm -rf /opt/glances
  # systemctl daemon-reload
  # 这样就能完全清理掉 Glances，而不会影响PVE系统、Python。
}

# 删除 GLANCES 硬件监控服务
del_install_glances_venv(){
  systemctl stop glances.service
  systemctl disable glances.service
  rm -f /etc/systemd/system/glances.service
  rm -f /usr/local/bin/glances  # 如果之前创建过glances命令的软链接，需要删除
  rm -rf /opt/glances
  systemctl daemon-reload
  green "删除完成"
}

# 不常用功能安装
Infreq_used() {
  local num
  clear
  green "============================================================="
  green "以下为不常用功能，可根据需要自行选择安装"
  green "============================================================="
  printfn
  green "1. 安装 GLANCES 硬件监控服务"
  green "2. 删除 GLANCES 硬件监控服务"
  blue "0. 返回上级菜单"
  printfn
  yellow_n "请输入数字选择你想要的执行项(0-2):"
  read num
  case "$num" in
  1)
  install_glances_venv
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  Infreq_used
  ;;
  2)
  del_install_glances_venv
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  Infreq_used
  ;;
  0)
  return 0
  ;;
  *)
  clear
  red "请输入正确数字(0-2)"
  sleep 1s
  Infreq_used
  ;;
  esac
}

# 开始菜单
start_menu(){
  local num
  clear
  # 获取 PVE 版本号
  # local PVE_VERSION=$(pveversion | awk '{print $1}' | cut -d'/' -f2 | cut -d' ' -f1 | cut -d'-' -f1)#此命令也可用，但较冗长
  local PVE_VERSION=$(pveversion | cut -d'/' -f2 | cut -d'-' -f1)
  #版本比较，判断是否版本低于 9.0.0
  if dpkg --compare-versions "$PVE_VERSION" "lt" "9.0.0"; then
    red "抱歉！当前版本 $PVE_VERSION 低于 9.0.0，此脚本不适用，自动退出。。。"
    sleep 1
    exit 1
  fi
  if [[ $EUID -ne 0 ]]; then
    red "错误：必须使用 root 用户运行此脚本！"
    exit 1
  fi
  clear
  green "当前 PVE 版本: $PVE_VERSION"
  green "=============================================================="
  cat << 'EOF'
 __       __  __      __        _______   __     __  ________ 
|  \     /  \|  \    /  \      |       \ |  \   |  \|        \
| $$\   /  $$ \$$\  /  $$      | $$$$$$$\| $$   | $$| $$$$$$$$
| $$$\ /  $$$  \$$\/  $$       | $$__/ $$| $$   | $$| $$__    
| $$$$\  $$$$   \$$  $$        | $$    $$ \$$\ /  $$| $$  \   
| $$\$$ $$ $$    \$$$$         | $$$$$$$   \$$\  $$ | $$$$$   
| $$ \$$$| $$    | $$          | $$         \$$ $$  | $$_____ 
| $$  \$ | $$    | $$          | $$          \$$$   | $$     \
 \$$      \$$     \$$           \$$           \$     \$$$$$$$$
EOF
  green "=============================================================="
  green "介绍："
  green "一键配置 PVE9 系统综合脚本"
  green "此脚本由dajiangfu编写并保持开源~"
  red "仅供技术交流使用，本脚本开源，请勿用于商业用途！"
  printfn
  green "1. 设置 web 登录页默认语言为简体中文"
  green "2. 删除 local_lvm"
  green "3. 取消无效订阅弹窗"
  green "4. PVE 软件源更换"
  green "5. 更新 pve 系统"
  green "6. 更新系统后执行系统清理程序"
  green "7. 开启 intel 核显 SR-IOV 虚拟化直通"
  green "8. 安装 UPS 监控软件 NUT"
  green "9. PVE 常用优化"
  green "10. 不常用功能安装"
  blue "0. 退出脚本"
  printfn
  # read -p "请输入数字选择你想要的执行项(0-10):" num
  yellow_n "请输入数字选择你想要的执行项(0-10):"
  read num
  case "$num" in
  1)
  set_default_language_zh_CN
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  2)
  delete_local_lvm
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  3)
  delete_invalid_subscription_popup
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  4)
  change_source
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  5)
  update_pve
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  6)
  cleanup_pve
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  7)
  install_intel_sr_iov_dkms
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  8)
  install_ups_nut
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  9)
  Kernel_opt
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  10)
  Infreq_used
  sleep 1s
  # read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  0)
  exit 0
  ;;
  *)
  clear
  red "请输入正确数字(0-10)"
  sleep 1s
  start_menu
  ;;
  esac
}

start_menu
