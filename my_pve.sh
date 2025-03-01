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

#����web��¼ҳĬ������Ϊ��������
function set_default_language_zh_CN(){
  echo 'language: zh_CN' >>/etc/pve/datacenter.cfg
  #��������
  systemctl restart pvedaemon.service
}

#ɾ��local_lvm
#PVE��װ�ú�ĵ�һ���¾���ɾ��local-lvm����
#PVEϵͳ�ڰ�װ��ʱ��Ĭ�ϻ�Ѵ��滮��Ϊlocal��local-lvm�����飬��ʵ��ʹ�õ�ʱ����������һ������������һ�����ܿյ����������ɾ��local-lvm�Ŀռ䣬Ȼ���ȫ�������local�������Լ�����
function delete_local_lvm(){
  lvremove pve/data
  lvextend -l +100%FREE -r pve/root
  #����������Ҫ�ֶ����뵽pve��webui��������������--�洢--local-lvm--�Ƴ���������ɾ����local-lvm�Ŀռ䡣
  #��������--�洢--local-�༭����������������е�ѡ�ѡ�ϣ�Ȼ����PVE�ڵ�ĸ�Ҫ�￴��Ӳ�̿ռ䣬���Կ����ռ䱻������������
}

#����pveϵͳ
function update_pve(){
  #������sources.list�ļ������龡����ʹ�ùٷ�Դ�����滻�ĵ�����Դ��������ʵ�������Ϲٷ�Դ��ʹ�õ�����Դ
  #���´洢��Ͱ�����������κδ������ʾ����sources.list�����������������Կ״̬����������
  apt update

  #���������
  apt dist-upgrade
}

#ȡ����Ч���ĵ���
function ()delete_invalid_subscription_popup{
  sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
  systemctl restart pveproxy.service
  # ִ����ɺ������Ctrl+F5ǿ��ˢ�»���
}

#PVE���Դ����
function change_source(){
  #ǿ�ҽ�����ɾ����ҵԴ
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

#����intel����SR-IOV���⻯ֱͨ
function open_intel_sr_iov(){
  # ��ȡ PVE �汾�ţ�ȥ���޹���Ϣ��
  PVE_VERSION=$(pveversion | awk '{print $1}' | cut -d'/' -f2 | cut -d'-' -f1)

  # ������ʼ��
  LOWER_VERSION=0

  # �汾�Ƚϣ�����汾����8.3.0��LOWER_VERSION=1
  if dpkg --compare-versions "$PVE_VERSION" "lt" "8.3.0"; then
    LOWER_VERSION=1
  fi

  # ������
  echo "��ǰ PVE �汾: $PVE_VERSION"
  if [ "$LOWER_VERSION" -eq 1 ]; then
    echo "��ǰ�汾����8.3.0"
  fi
  #Proxmox GRUB ���ã�Proxmox ��Ĭ�ϰ�װʹ�� GRUB �������س���
  #ע�⣺������ʹ�õ���PVE8.3��ϵͳĬ�Ͽ�����iommu,���"quiet iommu=pt i915.enable_guc=3 i915.max_vfs=3"��ʡȥ��intel_iommu=on��
  #�Ͱ汾ʹ��"quiet intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=3"
  cp -a /etc/default/grub{,.bak}
  if [ "$LOWER_VERSION" -eq 1 ]; then
    sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=3"' /etc/default/grub
  else
    sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt i915.enable_guc=3 i915.max_vfs=3"' /etc/default/grub
  fi
  
  #�����ں�ģ��:
  echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" >> /etc/modules
  #Ӧ���޸�
  update-grub
  update-initramfs -u -k all

  #��¡ DKMS repo ����һЩ��������
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

  #�������ں˲����״̬����֤���Ƿ���ʾ�Ѱ�װ
  VERSION=$(dkms status -m i915-sriov-dkms | cut -d':' -f1)
  dkms install -m $VERSION --force
  dkms status

  #����ȫ�°�װ�� Proxmox 8.1 �����߰汾���������ð�ȫ�������Է���һ��������Ҫ���� DKMS ��Կ���Ա��ں˼���ģ�顣
  #�����������Ȼ���������롣����������� MOK ���ã�������������ʱ���ٴ�ʹ�á��˺󣬲���Ҫ���롣
  #������Ҫ�������� root �ʻ���������ͬ��
  mokutil --import /var/lib/dkms/mok.pub

  #��� PCI ����
  #1. ����������Ҫ�ҵ� VGA ��λ���ĸ� PCIe �����ϡ�ͨ��VGA����IDΪ00:02.0
  # ��ȡ VGA �豸�� PCIe ���ߺ�
  vga_id=$(lspci | grep VGA | awk '{print $1}')

  # ȷ���ɹ���ȡ vga_id
  if [ -z "$vga_id" ]; then
    echo "δ�ҵ� VGA �豸������ lspci �����"
    exit 1
  fi

  #2. ���� sysfs ����
  echo "devices/pci0000:00/0000:$vga_id/sriov_numvfs = 3" > /etc/sysfs.conf

  # ������
  echo "��д�� /etc/sysfs.conf���������£�"
  #cat���ļ���ȷ�����ѱ��޸�
  cat /etc/sysfs.conf

  #3. ���� Proxmox ���������ʹ�� Proxmox 8.1 ����߰汾�����ð�ȫ��������������� MOK��
  #�� Proxmox ��������ʱ������������̲��ȴ�ִ�� MOK �����ڣ��������Ļ��ͼ����
  #�������˵�һ������������Ҫ�������� mokutil ����ٴ�������DKMS ģ�齫������أ�ֱ������ɴ�����
  #��PVE����ʱ����ʾ��������������ѡ��Enroll MOK--->Continue--->Yes--->password(����֮ǰ���õ�MOK����س�)--->Reboot
  #Ӳ���������PCI�豸��ѡ����������ļ���SR-IOV���ԣ�ע��Ҫ�ǵù�ѡ��GPU��PCI-Express����ʾ����ΪVirtlO-GPU����������̨���л���
  
  # ѯ���û��Ƿ�����
  read -p "��������ϣ��Ƿ�����ϵͳ�������� [Y/n]: " choice
  [ -z "${choice}" ] && choice="y"

  # �ж��û�����
  if [[ $choice == [Yy] ]]; then
    echo "ϵͳ���� 2 �������..."
    sleep 2
    reboot
  else
    echo "��ȡ�������Ժ�����������"
  fi
}

#��ʼ�˵�
start_menu(){
  clear
  green " ======================================="
  green " ���ܣ�"
  green " һ������PVEϵͳ�ۺϽű�"
  red " *������������ʹ�ã����ű���Դ������������ҵ��;�������޸�����Ҳ�в��߿�Դ��"
  green " ======================================="
  echo
  green " 1. ����web��¼ҳĬ������Ϊ��������"
  green " 2. ɾ��local_lvm"
  green " 3. ����pveϵͳ"
  green " 4. ȡ����Ч���ĵ���"
  green " 5. PVE���Դ����"
  green " 6. ����intel����SR-IOV���⻯ֱͨ"
  blue " 0. �˳��ű�"
  echo
  read -p "����������:" num
  case "$num" in
  1)
  set_default_language_zh_CN
  sleep 1s
  read -s -n1 -p "����������ز˵� ... "
  start_menu
  ;;
  2)
  delete_local_lvm
  sleep 1s
  read -s -n1 -p "����������ز˵� ... "
  start_menu
  ;;
  3)
  update_pve
  sleep 1s
  read -s -n1 -p "����������ز˵� ... "
  start_menu
  ;;
  4)
  delete_invalid_subscription_popup
  sleep 1s
  read -s -n1 -p "������������ϼ��˵� ... "
  start_menu
  ;;
  5)
  change_source
  sleep 1s
  read -s -n1 -p "����������ز˵� ... "
  start_menu
  ;;
  6)
  open_intel_sr_iov
  sleep 1s
  read -s -n1 -p "������������ϼ��˵� ... "
  start_menu
  ;;
  0)
  exit 1
  ;;
  *)
  clear
  red "��������ȷ����"
  sleep 1s
  start_menu
  ;;
  esac
}

start_menu
