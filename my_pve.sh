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

#设置web登录页默认语言为简体中文
function set_default_language_zh_CN(){
  echo 'language: zh_CN' >>/etc/pve/datacenter.cfg
  #重启服务
  systemctl restart pvedaemon.service
}

#删除local_lvm
#PVE安装好后的第一件事就是删除local-lvm分区
#PVE系统在安装的时候默认会把储存划分为local和local-lvm两个块，在实际使用的时候往往其中一个不够用了另一个还很空的情况，可以删除local-lvm的空间，然后把全部分配给local，方便自己管理
function delete_local_lvm(){
  lvremove pve/data
  lvextend -l +100%FREE -r pve/root
  #完成命令后需要手动进入到pve的webui操作，数据中心--存储--local-lvm--移除，这样就删掉了local-lvm的空间。
  #数据中心--存储--local-编辑，在内容这里，把所有的选项都选上，然后在PVE节点的概要里看下硬盘空间，可以看到空间被完整的利用了
}

#更新pve系统
function update_pve(){
  #检查你的sources.list文件，建议尽可能使用官方源不是替换的第三方源，如网络实在连不上官方源则使用第三方源
  #更新存储库和包，如果出现任何错误，则表示您的sources.list（或您的网络或订阅密钥状态）存在问题
  apt update

  #升级软件包
  apt dist-upgrade
}

#取消无效订阅弹窗
function ()delete_invalid_subscription_popup{
  sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
  systemctl restart pveproxy.service
  # 执行完成后，浏览器Ctrl+F5强制刷新缓存
}

#PVE软件源更换
function change_source(){
  #强烈建议先删除企业源
  rm /etc/apt/sources.list.d/pve-enterprise.list
  
  dir="/etc/apt/sources.list.d/"
  file="/etc/apt/sources.list"

  if [ -d "$dir" ]; then
    echo "Deleting directory $dir..."
    rm -rf "$dir"
    echo "Directory deleted."
  else
    echo "Directory $dir does not exist. Skipping deletion."
  fi

  echo "Replacing content of $file..."

  echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" > "$file"
  echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >> "$file"
  echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >> "$file"
  echo "deb https://mirrors.ustc.edu.cn/debian-security bookworm-security main" >> "$file"
  echo "deb https://mirrors.ustc.edu.cn/proxmox/debian bookworm pve-no-subscription" >> "$file"

  echo "Content replaced."
}

#开启intel核显SR-IOV虚拟化直通
function open_intel_sr_iov(){
  # 获取 PVE 版本号（去掉无关信息）
  PVE_VERSION=$(pveversion | awk '{print $1}' | cut -d'/' -f2 | cut -d'-' -f1)

  # 变量初始化
  LOWER_VERSION=0

  # 版本比较，如果版本低于8.3.0则LOWER_VERSION=1
  if dpkg --compare-versions "$PVE_VERSION" "lt" "8.3.0"; then
    LOWER_VERSION=1
  fi

  # 输出结果
  echo "当前 PVE 版本: $PVE_VERSION"
  if [ "$LOWER_VERSION" -eq 1 ]; then
    echo "当前版本低于8.3.0"
  fi
  #Proxmox GRUB 配置，Proxmox 的默认安装使用 GRUB 引导加载程序
  #注意：由于我使用的是PVE8.3，系统默认开启了iommu,因此"quiet iommu=pt i915.enable_guc=3 i915.max_vfs=3"中省去了intel_iommu=on，
  #低版本使用"quiet intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=3"
  cp -a /etc/default/grub{,.bak}
  if [ "$LOWER_VERSION" -eq 1 ]; then
    sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=3"' /etc/default/grub
  else
    sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt i915.enable_guc=3 i915.max_vfs=3"' /etc/default/grub
  fi
  
  #加载内核模块:
  echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" >> /etc/modules
  #应用修改
  update-grub
  update-initramfs -u -k all

  #克隆 DKMS repo 并做一些构建工作
  apt update && apt install git sysfsutils pve-headers mokutil -y
  rm -rf /usr/src/i915-sriov-dkms-*
  rm -rf /var/lib/dkms/i915-sriov-dkms
  rm -rf ~/i915-sriov-dkms*
  find /lib/modules -regex ".*/updates/dkms/i915.ko" -delete

  cd ~
  git clone https://github.com/strongtz/i915-sriov-dkms.git
  apt install build-* dkms
  cd ~/i915-sriov-dkms
  dkms add .

  #构建新内核并检查状态。验证它是否显示已安装
  VERSION=$(dkms status -m i915-sriov-dkms | cut -d':' -f1)
  dkms install -m $VERSION --force
  dkms status

  #对于全新安装的 Proxmox 8.1 及更高版本，可以启用安全启动。以防万一，我们需要加载 DKMS 密钥，以便内核加载模块。
  #运行以下命令，然后输入密码。此密码仅用于 MOK 设置，重新启动主机时将再次使用。此后，不需要密码。
  #它不需要与您用于 root 帐户的密码相同。
  mokutil --import /var/lib/dkms/mok.pub

  #完成 PCI 配置
  #1. 现在我们需要找到 VGA 卡位于哪个 PCIe 总线上。通常VGA总线ID为00:02.0
  # 获取 VGA 设备的 PCIe 总线号
  vga_id=$(lspci | grep VGA | awk '{print $1}')

  # 确保成功获取 vga_id
  if [ -z "$vga_id" ]; then
    echo "未找到 VGA 设备，请检查 lspci 输出！"
    exit 1
  fi

  #2. 生成 sysfs 配置
  echo "devices/pci0000:00/0000:$vga_id/sriov_numvfs = 3" > /etc/sysfs.conf

  # 输出结果
  echo "已写入 /etc/sysfs.conf，内容如下："
  #cat该文件并确保它已被修改
  cat /etc/sysfs.conf

  #3. 重启 Proxmox 主机。如果使用 Proxmox 8.1 或更高版本并启用安全启动，则必须设置 MOK。
  #在 Proxmox 主机重启时，监控启动过程并等待执行 MOK 管理窗口（下面的屏幕截图）。
  #如果错过了第一次重启，则需要重新运行 mokutil 命令并再次重启。DKMS 模块将不会加载，直到您完成此设置
  #在PVE重启时的显示器启动界面依次选择Enroll MOK--->Continue--->Yes--->password(输入之前设置的MOK密码回车)--->Reboot
  #硬件里面添加PCI设备可选择虚拟出来的几个SR-IOV核显，注意要记得勾选主GPU和PCI-Express，显示设置为VirtlO-GPU，这样控制台才有画面
  
  # 询问用户是否重启
  read -p "已设置完毕，是否重启系统？请输入 [Y/n]: " choice
  [ -z "${choice}" ] && choice="y"

  # 判断用户输入
  if [[ $choice == [Yy] ]]; then
    echo "系统将在 2 秒后重启..."
    sleep 2
    reboot
  else
    echo "已取消，请稍后自行重启。"
  fi
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
  green " 3. 更新pve系统"
  green " 4. 取消无效订阅弹窗"
  green " 5. PVE软件源更换"
  green " 6. 开启intel核显SR-IOV虚拟化直通"
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
  update_pve
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  4)
  delete_invalid_subscription_popup
  sleep 1s
  read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  5)
  change_source
  sleep 1s
  read -s -n1 -p "按任意键返回菜单 ... "
  start_menu
  ;;
  6)
  open_intel_sr_iov
  sleep 1s
  read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  0)
  exit 1
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
