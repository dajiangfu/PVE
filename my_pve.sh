#!/bin/bash

function blue(){
  echo -e "\033[34m\033[01m$1\033[0m"
}
function green(){
  echo -e "\033[32m\033[01m$1\033[0m"
}
function red(){
  echo -e "\033[31m\033[01m$1\033[0m"
}
function yellow(){
  echo -e "\033[33m\033[01m$1\033[0m"
}

#设置web登录页默认语言为简体中文
function set_default_language_zh_CN(){
  if grep -q "^language:" /etc/pve/datacenter.cfg; then
    sed -i 's/^language:.*/language: zh_CN/' /etc/pve/datacenter.cfg
  else
    echo 'language: zh_CN' >> /etc/pve/datacenter.cfg
  fi
  #重启服务
  systemctl restart pvedaemon.service
}

#删除local_lvm
#PVE安装好后的第一件事就是删除local-lvm分区
#PVE系统在安装的时候默认会把储存划分为local和local-lvm两个块，在实际使用的时候往往其中一个不够用了另一个还很空的情况，可以删除local-lvm的空间，然后把全部分配给local，方便自己管理
function delete_local_lvm(){
  if lvremove -y pve/data; then
    green "已删除 local-lvm"
  else
    red "lvremove 失败，请检查 LVM 配置！"
  fi
  if lvextend -l +100%FREE -r pve/root; then
    green "已成功扩展 root 分区"
    green "1、请进入到pve的webui"
    green "2、执行 数据中心--存储--local-lvm--移除，这样就删掉了local-lvm的空间"
    green "3、执行 数据中心--存储--local-编辑，在内容这里，把所有的选项都选上，然后在PVE节点的概要里看下硬盘空间，可以看到空间被完整的利用了"
  else
    red "lvextend 扩展失败，请检查存储空间是否足够！"
  fi
}

#取消无效订阅弹窗
function delete_invalid_subscription_popup(){
  sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
  systemctl restart pveproxy.service
  green "执行完成后，浏览器Ctrl+F5强制刷新缓存"
}

#PVE软件源更换
function change_source(){
  #强烈建议先删除企业源
  if [ -f "/etc/apt/sources.list.d/pve-enterprise.list" ]; then
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    green "已删除 pve-enterprise.list"
  else
    yellow "pve-enterprise.list 不存在，跳过删除"
  fi
  
  dir="/etc/apt/sources.list.d/"
  file="/etc/apt/sources.list"

  if [ -d "$dir" ]; then
    echo "正在删除目录 $dir..."
    if rm -rf "$dir"; then
        green "删除完成"
    else
        red "删除失败"
    fi
  else
    yellow "目录 $dir 不存在，跳过删除"
  fi

  echo "正在替换 $file 中的内容..."

  echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" > "$file"
  echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >> "$file"
  echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >> "$file"
  echo "deb https://mirrors.ustc.edu.cn/debian-security bookworm-security main" >> "$file"
  echo "deb https://mirrors.ustc.edu.cn/proxmox/debian bookworm pve-no-subscription" >> "$file"

  green "替换完成！"
}

#更新pve系统
function update_pve(){
  #检查你的sources.list文件，建议尽可能使用官方源不是替换的第三方源，如网络实在连不上官方源则使用第三方源
  if ! apt update; then
    red "存储库更新失败，请检查网络或 sources.list 配置或订阅密钥状态！"
    return 1
  fi

  green "升级软件包..."
  if ! apt dist-upgrade -y; then
    red "软件包升级失败，请检查错误日志！"
    return 1
  fi
  #询问用户是否重启
  read -p "已更新完毕，是否重启系统？请输入 [Y/n]: " choice
  choice=$(echo "$choice" | tr 'A-Z' 'a-z')  # 转换为小写，兼容性好，也可以用更现代的choice=${choice,,}
  [ -z "${choice}" ] && choice="y"
  if [[ "$choice" == "y" ]]; then
    green "系统将在 2 秒后重启..."
    sleep 2
    reboot
  else
    blue "已取消，请稍后自行重启。"
  fi
}

#开启intel核显SR-IOV虚拟化直通
function install_intel_sr_iov_dkms(){
  #克隆 DKMS repo 并做一些构建工作
  apt update && apt install git sysfsutils pve-headers mokutil -y
  rm -rf /usr/src/i915-sriov-dkms-*
  rm -rf /var/lib/dkms/i915-sriov-dkms
  rm -rf ~/i915-sriov-dkms*
  find /lib/modules -regex ".*/updates/dkms/i915.ko" -delete

  cd ~
  git clone https://github.com/strongtz/i915-sriov-dkms.git
  #apt install build-* dkms
  #build-* 是 通配符匹配，它会安装所有以 build- 开头的包，这可能包括大量不必要的软件。
  #build-* 并不是一个官方推荐的安装方式，它可能会匹配到 大量不相关的软件
  #不推荐 直接使用 build-*，因为它可能会安装许多你 不需要的构建工具，导致系统安装冗余包
  #不建议使用 build-*，可能会安装不相关的包，占用磁盘空间并影响系统稳定性
  apt install build-essential dkms -y
  cd ~/i915-sriov-dkms
  if ! dkms add .; then
    red "DKMS 添加失败，退出！"
    return 1
  fi

  #构建新内核并检查状态。验证它是否显示已安装
  VERSION=$(dkms status -m i915-sriov-dkms | cut -d':' -f1)
  if [ -z "$VERSION" ]; then
    red "无法获取 i915-sriov-dkms 版本，退出！"
    return 1
  fi
  if ! dkms install -m "$VERSION" --force; then
    red "DKMS 安装失败！请检查以下内容："
    red "1. 是否已安装 build-essential 和 dkms"
    red "2. 是否有足够的磁盘空间"
    red "3. 运行 dkms status 确保模块被正确识别"
    return 1
  fi
  #运行 dkms status 并检查i915-sriov-dkms是否已安装"
  if dkms status -m i915-sriov-dkms | grep -iqE ":\s+installed$"; then
    green "i915-sriov-dkms已安装，继续..."
  else
    red "i915-sriov-dkms未安装，退出！"
    return 1
  fi

  #对于全新安装的 Proxmox 8.1 及更高版本，可以启用安全启动。以防万一，我们需要加载 DKMS 密钥，以便内核加载模块。
  #运行以下命令，然后输入密码。此密码仅用于 MOK 设置，重新启动主机时将再次使用。此后，不需要密码。
  #它不需要与您用于 root 帐户的密码相同。
  green "加载 DKMS 密钥"
  mokutil --import /var/lib/dkms/mok.pub
  
  #获取 PVE 版本号（去掉无关信息）
  LOWER_VERSION=0
  #PVE_VERSION=$(pveversion | awk '{print $1}' | cut -d'/' -f2 | cut -d' ' -f1 | cut -d'-' -f1)#此命令也可用，但较冗长
  PVE_VERSION=$(pveversion | cut -d'/' -f2 | cut -d'-' -f1)
  echo "当前 PVE 版本: $PVE_VERSION"
  #版本比较，判断是否版本低于8.3.0
  if dpkg --compare-versions "$PVE_VERSION" "lt" "8.3.0"; then
    blue "当前版本低于8.3.0"
    LOWER_VERSION=1
  fi
  
  #Proxmox GRUB 配置，Proxmox 的默认安装使用 GRUB 引导加载程序
  #注意：由于我使用的是PVE8.3，系统默认开启了iommu,因此"quiet iommu=pt i915.enable_guc=3 i915.max_vfs=3"中省去了intel_iommu=on，
  #低版本使用"quiet intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=3"
  cp -a /etc/default/grub{,.bak}
  if [ "$LOWER_VERSION" -eq 1 ]; then
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=3"' /etc/default/grub
  else
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt i915.enable_guc=3 i915.max_vfs=3"' /etc/default/grub
  fi
  
  #加载内核模块:
  echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" >> /etc/modules
  #应用修改
  update-grub
  update-initramfs -u -k all

  #完成 PCI 配置
  #现在我们需要找到 VGA 卡位于哪个 PCIe 总线上。通常VGA总线ID为00:02.0
  #获取 VGA 设备的 PCIe 总线号
  vga_id=$(lspci | grep VGA | awk '{print $1}')

  #确保成功获取 vga_id
  if [ -z "$vga_id" ]; then
    red "未找到 VGA 设备，请检查 lspci 输出！"
    return 1
  fi

  #生成 sysfs 配置
  echo "devices/pci0000:00/0000:$vga_id/sriov_numvfs = 3" > /etc/sysfs.conf

  #输出结果
  echo "已写入 /etc/sysfs.conf，内容如下："
  #cat该文件并确保它已被修改
  cat /etc/sysfs.conf
  
  #重启 Proxmox 主机。如果使用 Proxmox 8.1 或更高版本并启用安全启动，则必须设置 MOK。
  #在 Proxmox 主机重启时，监控启动过程并等待执行 MOK 管理窗口（下面的屏幕截图）。
  #如果错过了第一次重启，则需要重新运行 mokutil 命令并再次重启。DKMS 模块将不会加载，直到您完成此设置
  #在PVE重启时的显示器启动界面依次选择Enroll MOK--->Continue--->Yes--->password(输入之前设置的MOK密码回车)--->Reboot
  #硬件里面添加PCI设备可选择虚拟出来的几个SR-IOV核显，注意要记得勾选主GPU和PCI-Express，显示设置为VirtlO-GPU，这样控制台才有画面
  #询问用户是否重启
  read -p "已设置完毕，是否重启系统？请输入 [Y/n]: " choice
  choice=$(echo "$choice" | tr 'A-Z' 'a-z')  # 转换为小写，兼容性好，也可以用更现代的choice=${choice,,}
  [ -z "${choice}" ] && choice="y"
  if [[ "$choice" == "y" ]]; then
    green "系统将在 2 秒后重启..."
    sleep 2
    reboot
  else
    blue "已取消，请稍后自行重启。"
  fi
}

#安装UPS监控软件NUT
function install_ups_nut(){
  apt update
  apt install -y nut #nut包通常会安装一些常见的依赖包，如 nut-client、nut-server、nut-cgi、nut-scanner，因此你可能不需要手动安装这些组件。
  #查看UPS设备硬件信息
  # nut-scanner #需要用户交互，在扫描过程中可能会提示用户做出选择，这个命令用于扫描计算机上连接的 UPS 设备，检查系统是否能够识别和通信，它会尝试自动检测并列出所有可用的 UPS 设备。
  nut-scanner -U #-U 选项用于使扫描器以 "不带用户交互" 的方式运行，会自动执行扫描，不会要求用户输入任何内容，适合自动化操作。
  green "安装NUT完成！下面进行配置"
  #GitHub文件路径
  BASE_URL="https://raw.githubusercontent.com/dajiangfu/PVE/main/nut"

  #目标目录
  DEST_DIR="/etc/nut"

  #文件列表
  FILES=("nut.conf" "ups.conf" "upsd.conf" "upsd.users" "upsmon.conf" "upssched.conf" "upssched-cmd")

  #确保目标目录存在
  if [ ! -d "$DEST_DIR" ]; then
    blue "目录 $DEST_DIR 不存在，开始创建..."
    mkdir -p "$DEST_DIR"
  fi

  #下载文件并保存到 /etc/nut 目录
  for FILE in "${FILES[@]}"; do
    green "下载 $FILE..."
    curl -s -o "$DEST_DIR/$FILE" "$BASE_URL/$FILE"
    if [ $? -eq 0 ]; then
      green "$FILE 已下载并保存到 $DEST_DIR."
    else
      red "$FILE下载失败，请检擦网络！"
	  return 1
    fi
  done

  green "所有文件下载成功"
  
  UPSD_USERS_FILE="/etc/nut/upsd.users"
  UPSMON_CONF_FILE="/etc/nut/upsmon.conf"

  #旧的用户名和密码
  OLD_USERNAME="monusername"
  OLD_PASSWORD="mima"

  #提示用户输入新的用户名和密码
  read -p "请输入新的用户名: " NEW_USERNAME
  read -sp "请输入新的密码: " NEW_PASSWORD
  echo ""

  #备份原始文件
  cp "$UPSD_USERS_FILE" "$UPSD_USERS_FILE.bak"
  cp "$UPSMON_CONF_FILE" "$UPSMON_CONF_FILE.bak"

  #使用sed替换用户名和密码
  sed -i "s/$OLD_USERNAME/$NEW_USERNAME/g" "$UPSD_USERS_FILE" "$UPSMON_CONF_FILE"
  sed -i "s/$OLD_PASSWORD/$NEW_PASSWORD/g" "$UPSD_USERS_FILE" "$UPSMON_CONF_FILE"

  green "配置更新完成！重启服务..."
  
  chown root:nut /etc/nut/upssched-cmd
  chmod 750 /etc/nut/upssched-cmd
  systemctl restart nut-server
  systemctl restart nut-server
  systemctl restart nut-monitor
  upsc tgbox850@localhost
}

#安装GLANCES硬件监控服务
function install_glances_venv(){
  #设置Glances安装目录
  GLANCES_DIR="/opt/glances"

  #安装Python和venv
  green "🐍 安装Python及venv..."
  apt update
  apt install -y python3 python3-venv python3-pip

  #创建venv
  green "📦 创建Python虚拟环境..."
  python3 -m venv $GLANCES_DIR

  #激活venv并安装Glances，激活venv后使用pip安装软件不会影响PVE系统所有安装的Python包都只会存放在/opt/glances目录，不会污染系统
  green "⚙ 进入虚拟环境并安装Glances..."
  source $GLANCES_DIR/bin/activate
  pip install --upgrade pip
  pip install glances

  #退出venv，退出venv后，pip重新指向系统Python，你的venv仍然保留，但不会影响其他操作。
  deactivate

  #询问用户是否启用WebUI
  read -p "❓ 是否启用Glances WebUI（默认仅API模式）？[Y/n] " enable_web
  enable_web=${enable_web:-N}  #默认不启用WebUI

  #选择Glances启动模式并自动设置Description
  GLANCES_OPTIONS="--server"
  DESCRIPTION="Glances API Mode"
  if [[ "$enable_web" =~ ^[Yy]$ ]]; then
    GLANCES_OPTIONS="$GLANCES_OPTIONS -w"
	DESCRIPTION="Glances API and WebUI Mode"
  fi

  #创建systemd服务文件
  green "🛠 创建 systemd 服务..."
cat << EOF > /etc/systemd/system/glances.service
[Unit]
Description=$DESCRIPTION
After=network.target

[Service]
ExecStart=$GLANCES_DIR/bin/glances $GLANCES_OPTIONS
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

  #重新加载systemd并启动Glances
  green "🚀 启动Glances..."
  systemctl daemon-reload
  #systemctl enable glances
  #systemctl start glances
  systemctl enable --now glances
  #systemctl enable --now glances 的作用
  #这个命令等同于两步操作：
  #systemctl enable glances   # 设置开机自启
  #systemctl start glances    # 立即启动服务
  #--now 选项表示同时启用（开机自启）并立即启动该服务。

  #获取PVEIP地址
  PVE_IP=$(hostname -I | awk '{print $1}')

  green "✅ Glances 安装完成！"
  green "📡 API访问地址: http://$PVE_IP:61208"
  green "📡 现在可以在Home Assistant添加Glances监控 PVE！"
  if [[ "$enable_web" =~ ^[Yy]$ ]]; then
    green "🌐 WebUI访问地址: http://$PVE_IP:61208"
  fi
  #显示最终的服务描述
  blue "📜 服务描述: $DESCRIPTION"
  #如果以后不再需要Glances或其他Python软件，直接删除venv目录即可：
  #rm -rf /opt/glances
  #这样就能完全清理掉Glances，而不会影响PVE系统、Python。
}

#开始菜单
start_menu(){
  clear
  green " ======================================="
  green " 介绍："
  green " 一键配置PVE系统综合脚本"
  red " *仅供技术交流使用，本脚本开源，请勿用于商业用途！如有修改新增也行不吝开源！"
  green " ======================================="
  echo
  green " 1. 设置web登录页默认语言为简体中文"
  green " 2. 删除local_lvm"
  green " 3. 取消无效订阅弹窗"
  green " 4. PVE软件源更换"
  green " 5. 更新pve系统"
  green " 6. 开启intel核显SR-IOV虚拟化直通"
  green " 7. 安装UPS监控软件NUT"
  green " 8. 安装GLANCES硬件监控服务"
  blue " 0. 退出脚本"
  echo
  read -p "请输入数字:" num
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
  read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  5)
  update_pve
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  6)
  install_intel_sr_iov_dkms
  sleep 1s
  read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  7)
  install_ups_nut
  sleep 1s
  read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  8)
  install_glances_venv
  sleep 1s
  read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  0)
  exit 0
  ;;
  *)
  clear
  red "请输入正确数字"
  sleep 1s
  start_menu
  ;;
  esac
}

start_menu
