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
  #apt install build-essential dkms -y
  apt install build-essential dkms
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

function chSensors(){
#安装lm-sensors并配置在界面上显示
#for i in `sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors|sed '/Chip /d'|sed '/cut/d'`;do modprobe $i;done
clear
x=$(whiptail --title " PveTools   Version : 2.4.0 " --menu "配置Sensors:" 25 60 15 \
"a" "安装配置温度、CPU频率显示" \
"b" "删除配置" \
3>&1 1>&2 2>&3)
exitstatus=$?
if [ $exitstatus = 0 ]; then
    case "$x" in
    a )
        if(whiptail --title "Yes/No" --yesno "
Your OS：$pve, you will install sensors interface, continue?(y/n)
您的系统是：$pve, 您将安装sensors界面，是否继续？(y/n)
            " 10 60) then
            js='/usr/share/pve-manager/js/pvemanagerlib.js'
            pm='/usr/share/perl5/PVE/API2/Nodes.pm'
            sh='/usr/bin/s.sh'
            ppv=`/usr/bin/pveversion`
            OS=`echo $ppv|awk -F'-' 'NR==1{print $1}'`
            ver=`echo $ppv|awk -F'/' 'NR==1{print $2}'|awk -F'-' '{print $1}'`
            bver=`echo $ppv|awk -F'/' 'NR==1{print $2}'|awk -F'.' '{print $1}'`
            pve=$OS$ver
            mkdir /etc/pvetools/
            if [ ! -f $js ];then
                cp $js /etc/pvetools/pvemanagerlib.js
            fi
            if [ ! -f $pm ];then
                cp $pm /etc/pvetools/Nodes.pm
            fi
            if [[ "$OS" != "pve" ]];then
                whiptail --title "Warnning" --msgbox "
您的系统不是Proxmox VE, 无法安装!
                " 10 60
                if [[ "$bver" != "5" || "$bver" != "6" || "$bver" != "7" ]];then
                    whiptail --title "Warnning" --msgbox "
您的系统版本无法安装!
                    " 10 60
                    start_menu
                fi
                start_menu
            fi
            if [[ ! -f "$js" || ! -f "$pm" ]];then
                whiptail --title "Warnning" --msgbox "
您的Proxmox VE版本不支持此方式！
                " 10 60
                start_menu
            fi
            #if [[ -f "$js.backup" && -f "$sh" ]];then
            if [[ `cat $js|grep Sensors|wc -l` -gt 0 ]];then
                whiptail --title "Warnning" --msgbox "
您已经安装过本软件，请不要重复安装！
                " 10 60
                chSensors
            fi
            if [ ! -f "/usr/bin/sensors" ];then
                apt-get -y install lm-sensors
            fi
            sensors-detect --auto > /tmp/sensors
            drivers=`sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors|sed '/Chip /d'|sed '/cut/d'`
            if [ `echo $drivers|wc -w` = 0 ];then
                whiptail --title "Warnning" --msgbox "
没有找到任何驱动，似乎你的系统没有温度传感器。
继续配置CPU频率...
                " 10 60
                if [ $bver -gt 7 ];then
                    cat << EOF > /usr/bin/s.sh
curC=\`cat /proc/cpuinfo|grep MHz|awk 'NR==1{print \$4}'\`
max=\`cat /proc/cpuinfo|grep GHz|awk -F "@" 'NR==1{print \$2}'|sed 's/GHz//g'|sed 's/\ //g'\`
maxC=\`echo "\$max * 1000"|bc -l\`
minC=\`lscpu|grep 'min MHz'|awk '{print \$4}'\`
c="\"CPU-MHz\":\""\$curC"\",\"CPU-max-MHz\":\""\$maxC"\",\"CPU-min-MHz\":\""\$minC"\""
r="{"\$c"}"
echo \$r
EOF
                else
                    cat << EOF > /usr/bin/s.sh
c=\`lscpu|grep MHz|sed 's/CPU\ /CPU-/g'|sed 's/\ MHz/-MHz/g'|sed 's/\ //g'|sed 's/^/"/g'|sed 's/$/"\,/g'|sed 's/\:/\"\:\"/g'|awk 'BEGIN{ORS=""}{print \$0}'|sed 's/\,\$//g'\`
r="{"\$c"}"
echo \$r
EOF
                fi
            chmod +x /usr/bin/s.sh
            #--create the configs--
            if [ -f ./p1 ];then rm ./p1;fi
            #--这里插入cpu频率--
            cat << EOF >> ./p1
             ,{
             itemId: 'MHz',
             colspan: 2,
             printBar: false,
             title: gettext('CPU频率'),
             textField: 'tdata',
             renderer:function(value){
                 var d = JSON.parse(value);
                 f0 = d['CPU-MHz'];
                 f1 = d['CPU-min-MHz'];
                 f2 = d['CPU-max-MHz'];
                 return  \`CPU实时(Cur): \${f0} MHz | 最小(min): \${f1} MHz | 最大(max): \${f2} MHz \`;
         }
 }
EOF
            #--插入cpu频率结束--
            cat << EOF >> ./p2
\$res->{tdata} = \`/usr/bin/s.sh\`;
EOF
            n=`sed '/pveversion/,/\}/=' $js -n|sed -n '$p'`
            sed -i ''$n' r ./p1' $js
            n=`sed '/pveversion/,/version_text/=' $pm -n|sed -n '$p'`
            sed -i ''$n' r ./p2' $pm
            if [ -f ./p1 ];then rm ./p1;fi
            if [ -f ./p2 ];then rm ./p2;fi
            systemctl restart pveproxy
            whiptail --title "Success" --msgbox "
如果没有意外，已经安装完成！浏览器打开界面刷新看一下概要界面！
            " 10 60

                chSensors
            else
                for i in $drivers
                do
                    modprobe $i
                    if [ `grep $i /etc/modules|wc -l` = 0 ];then
                        echo $i >> /etc/modules
                    fi
                done
                sensors
                sleep 3
                whiptail --title "Success" --msgbox "
安装配置成功，如果没有意外，上面已经显示sensors。下一步会重启web界面，请不要惊慌。
                " 20 60
            rm /tmp/sensors
            #debian 12 fixbug
            if [ $bver -gt 7 ];then
                cat << EOF > /usr/bin/s.sh
r=\`sensors|grep -E 'Package id 0|fan|Physical id 0|Core'|grep '^[a-zA-Z0-9].[[:print:]]*:.\s*\S*[0-9].\s*[A-Z].' -o|sed 's/:\ */:/g'|sed 's/:/":"/g'|sed 's/^/"/g' |sed 's/$/",/g'|sed 's/\ C\ /C/g'|sed 's/\ V\ /V/g'|sed 's/\ RP/RPM/g'|sed 's/\ //g'|awk 'BEGIN{ORS=""}{print \$0}'|sed 's/\,\$//g'|sed 's/°C/\&degC/g'\`
curC=\`cat /proc/cpuinfo|grep MHz|awk 'NR==1{print \$4}'\`
max=\`cat /proc/cpuinfo|grep GHz|awk -F "@" 'NR==1{print \$2}'|sed 's/GHz//g'|sed 's/\ //g'\`
maxC=\`echo "\$max * 1000"|bc -l\`
minC=\`lscpu|grep 'min MHz'|awk '{print \$4}'\`
c="\"CPU-MHz\":\""\$curC"\",\"CPU-max-MHz\":\""\$maxC"\",\"CPU-min-MHz\":\""\$minC"\""
r="{"\$r","\$c"}"
echo \$r
EOF
            else
                cat << EOF > /usr/bin/s.sh
r=\`sensors|grep -E 'Package id 0|fan|Physical id 0|Core'|grep '^[a-zA-Z0-9].[[:print:]]*:.\s*\S*[0-9].\s*[A-Z].' -o|sed 's/:\ */:/g'|sed 's/:/":"/g'|sed 's/^/"/g' |sed 's/$/",/g'|sed 's/\ C\ /C/g'|sed 's/\ V\ /V/g'|sed 's/\ RP/RPM/g'|sed 's/\ //g'|awk 'BEGIN{ORS=""}{print \$0}'|sed 's/\,\$//g'|sed 's/°C/\&degC/g'\`
c=\`lscpu|grep MHz|sed 's/CPU\ /CPU-/g'|sed 's/\ MHz/-MHz/g'|sed 's/\ //g'|sed 's/^/"/g'|sed 's/$/"\,/g'|sed 's/\:/\"\:\"/g'|awk 'BEGIN{ORS=""}{print \$0}'|sed 's/\,\$//g'\`
r="{"\$r","\$c"}"
echo \$r
EOF
            fi
            chmod +x /usr/bin/s.sh
            #--create the configs--
            #--filter for sensors 过滤sensors项目--
            d=`sensors|grep -E 'Package id 0|fan|Physical id 0|Core'|grep '^[a-zA-Z0-9].[[:print:]]*:.\s*\S*[0-9].\s*[A-Z].' -o|sed 's/:\ */:/g'|sed 's/\ C\ /C/g'|sed 's/\ V\ /V/g'|sed 's/\ RP/RPM/g'|sed 's/\ //g'|awk -F ":" '{print $1}'`
            if [ -f ./p1 ];then rm ./p1;fi
            #--这里插入cpu频率--
            cat << EOF >> ./p1
             ,{
             itemId: 'MHz',
             colspan: 2,
             printBar: false,
             title: gettext('CPU频率'),
             textField: 'tdata',
             renderer:function(value){
                 var d = JSON.parse(value);
                 f0 = d['CPU-MHz'];
                 f1 = d['CPU-min-MHz'];
                 f2 = d['CPU-max-MHz'];
                 return  \`CPU实时(Cur): \${f0} MHz | 最小(min): \${f1} MHz | 最大(max): \${f2} MHz \`;
         }
 }
EOF
            #--插入cpu频率结束--
            cat << EOF >> ./p1
        ,{
            xtype: 'box',
            colspan: 2,
        title: gettext('Sensors Data:'),
            padding: '0 0 20 0'
        }
        ,{
            itemId: 'Sensors',
            colspan: 2,
            printBar: false,
            title: gettext('Sensors Data:')
        }
EOF
            for i in $d
            do
            cat << EOF >> ./p1
        ,{
            itemId: '$i',
            colspan: 1,
            printBar: false,
            title: gettext('$i'),
            textField: 'tdata',
            renderer:function(value){
            var d = JSON.parse(value);
            var s = "";
            s = d['$i'];
            return s;
            }
        }
EOF
            done
            cat << EOF >> ./p2
\$res->{tdata} = \`/usr/bin/s.sh\`;
EOF
#\$res->{cpusensors} = \`lscpu | grep MHz\`;
            #--configs end--
            #h=`sensors|awk 'END{print NR}'`
            itemC=`s.sh|sed  's/\,/\r\n/g'|wc -l`
            if [ $itemC = 0 ];then
                h=400
            else
                #let h=$h*9+320
                let h=$itemC*24/2+360
            fi
            n=`sed '/widget.pveNodeStatus/,/height/=' $js -n|sed -n '$p'`
            sed -i ''$n'c \ \ \ \ height:\ '$h',' $js
            n=`sed '/pveversion/,/\}/=' $js -n|sed -n '$p'`
            sed -i ''$n' r ./p1' $js
            n=`sed '/pveversion/,/version_text/=' $pm -n|sed -n '$p'`
            sed -i ''$n' r ./p2' $pm
            if [ -f ./p1 ];then rm ./p1;fi
            if [ -f ./p2 ];then rm ./p2;fi
            systemctl restart pveproxy
            whiptail --title "Success" --msgbox "
如果没有意外，已经安装完成！浏览器打开界面刷新看一下概要界面！
            " 10 60
        fi
        else
            chSensors
        fi
    ;;
    b )
        if(whiptail --title "Yes/No" --yesno "
确认要还原配置？
        " 10 60)then
            js='/usr/share/pve-manager/js/pvemanagerlib.js'
            pm='/usr/share/perl5/PVE/API2/Nodes.pm'

            if [[ `cat $js|grep -E 'Sensors|CPU'|wc -l` = 0 ]];then
                whiptail --title "Warnning" --msgbox "
没有检测到安装，不需要卸载。
                " 10 60
            else
                sensors-detect --auto > /tmp/sensors
                drivers=`sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors|sed '/Chip /d'|sed '/cut/d'`
                if [ `echo $drivers|wc -w` != 0 ];then
                    for i in $drivers
                    do
                        if [ `grep $i /etc/modules|wc -l` != 0 ];then
                            sed -i '/'$i'/d' /etc/modules
                        fi
                    done
                fi
                apt-get -y remove lm-sensors
            {
                #mv $js.backup $js
                #mv $pm.backup $pm
                #rm $js
                #rm $pm
                rm /usr/bin/s.sh
                #cp /etc/pvetools/pvemanagerlib.js $js
                #cp /etc/pvetools/Nodes.pm $pm
                apt install --reinstall pve-manager
                systemctl restart pveproxy
                echo 50
                echo 100
                sleep 1
            }|whiptail --gauge "Uninstalling" 10 60 0
            whiptail --title "Success" --msgbox "
卸载成功。
            " 10 60
            fi
        fi
        chSensors
        ;;
    esac
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
  green " 7. 配置pve的web界面显示传感器温度、CPU频率"
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
  install_intel_sr_iov_dkms
  sleep 1s
  read -s -n1 -p "按任意键返回上级菜单 ... "
  start_menu
  ;;
  7)
  chSensors
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
