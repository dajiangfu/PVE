#!/bin/bash

  #此脚本从pvetools.sh中提取，如需更新可下载pvetools重新提取
  #安装lm-sensors并配置在界面上显示
  #for i in `sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors|sed '/Chip /d'|sed '/cut/d'`;do modprobe $i;done
  #这个脚本 不只是修改 pvemanagerlib.js 和 Nodes.pm，还会：
  #1、安装 lm-sensors，并修改 /etc/modules 让驱动自动加载
  #2、创建 /usr/bin/s.sh，用于 PVE Web UI 获取 CPU 频率和温度数据
  #3、修改 PVE Web UI，可能影响 Web 界面功能
  #4、重启 PVE Web 服务，可能导致 Web UI 失效
  #⚠ 风险：
  #如果 lm-sensors 驱动不兼容，可能导致传感器无法使用甚至系统不稳定
  #如果 /usr/bin/s.sh 生成的数据异常，PVE Web 界面可能崩溃
  #修改 pvemanagerlib.js 和 Nodes.pm 可能影响 PVE 更新，甚至导致 Web UI 失效
  #✅ 降低风险的方法：

  #1、手动备份 /usr/share/pve-manager/js/pvemanagerlib.js 和 /usr/share/perl5/PVE/API2/Nodes.pm
  #cp /usr/share/pve-manager/js/pvemanagerlib.js /root/pvemanagerlib.js.bak
  #cp /usr/share/perl5/PVE/API2/Nodes.pm /root/Nodes.pm.bak
  #2、先测试 lm-sensors 是否正常工作：
  #apt-get install lm-sensors
  #sensors-detect --auto
  #sensors
  
  #如果遇到问题，手动恢复的步骤：
  #1、恢复pvemanagerlib.js和Nodes.pm（手动备份或 apt-get install --reinstall pve-manager）
  #cp /root/pvemanagerlib.js.bak /usr/share/pve-manager/js/pvemanagerlib.js
  #cp /root/Nodes.pm.bak /usr/share/perl5/PVE/API2/Nodes.pm
  #2、卸载 lm-sensors
  #apt-get remove --purge lm-sensors -y
  #3、清理 /etc/modules 里的传感器驱动
  #脚本会把传感器驱动写入 /etc/modules，可以手动清理：
  #nano /etc/modules
  #删除 modprobe 加载的驱动（如果有的话），然后保存并退出（Ctrl+X -> Y -> Enter）
  #4、删除 /usr/bin/s.sh
  #rm -f /usr/bin/s.sh
  #5、重启 PVE Web 代理
  #systemctl restart pveproxy
  #⚠ 恢复后建议刷新浏览器缓存，以确保 Web UI 正常显示。
  
  clear
  x=$(whiptail --title " PveTools   Version : 2.4.0 " --menu "配置Sensors:" 25 60 15 \
"a" "安装配置温度、CPU频率显示" \
"b" "删除配置" \
3>&1 1>&2 2>&3)
  exitstatus=$?
  if [ $exitstatus = 0 ]; then
    case "$x" in
    a )
      if(whiptail --title "Yes/No" --yesno "您的系统是：$pve, 您将安装sensors界面，是否继续？(y/n)" 10 60) then
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
          whiptail --title "Warnning" --msgbox "您的系统不是Proxmox VE, 无法安装!" 10 60
          if [[ "$bver" != "5" || "$bver" != "6" || "$bver" != "7" ]];then
            whiptail --title "Warnning" --msgbox "您的系统版本无法安装!" 10 60
            start_menu
          fi
          start_menu
        fi
        if [[ ! -f "$js" || ! -f "$pm" ]];then
          whiptail --title "Warnning" --msgbox "您的Proxmox VE版本不支持此方式！" 10 60
          start_menu
        fi
        #if [[ -f "$js.backup" && -f "$sh" ]];then
        if [[ `cat $js|grep Sensors|wc -l` -gt 0 ]];then
          whiptail --title "Warnning" --msgbox "您已经安装过本软件，请不要重复安装！" 10 60
          chSensors
        fi
        if [ ! -f "/usr/bin/sensors" ];then
          apt-get -y install lm-sensors
        fi
        sensors-detect --auto > /tmp/sensors
        drivers=`sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors|sed '/Chip /d'|sed '/cut/d'`
        if [ `echo $drivers|wc -w` = 0 ];then
            whiptail --title "Warnning" --msgbox "没有找到任何驱动，似乎你的系统没有温度传感器。继续配置CPU频率..." 10 60
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
            if [ -f ./p1 ];then
              rm ./p1;
            fi
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
                 return  \`CPU实时: \${f0} MHz | 最小: \${f1} MHz | 最大: \${f2} MHz \`;
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
            if [ -f ./p1 ];then
              rm ./p1;
            fi
            if [ -f ./p2 ];then
              rm ./p2;
            fi
            systemctl restart pveproxy
            whiptail --title "Success" --msgbox "如果没有意外，已经安装完成！浏览器打开界面刷新看一下概要界面！" 10 60
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
          whiptail --title "Success" --msgbox "安装配置成功，如果没有意外，上面已经显示sensors。下一步会重启web界面，请不要惊慌。" 20 60
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
          if [ -f ./p1 ];then
            rm ./p1;
          fi
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
                 return  \`CPU实时: \${f0} MHz | 最小: \${f1} MHz | 最大: \${f2} MHz \`;
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
          if [ -f ./p1 ];then
            rm ./p1;
          fi
          if [ -f ./p2 ];then
            rm ./p2;
          fi
          systemctl restart pveproxy
          whiptail --title "Success" --msgbox "如果没有意外，已经安装完成！浏览器打开界面刷新看一下概要界面！" 10 60
        fi
      else
        chSensors
      fi
    ;;
    b )
      if(whiptail --title "Yes/No" --yesno "确认要还原配置？" 10 60)then
        js='/usr/share/pve-manager/js/pvemanagerlib.js'
        pm='/usr/share/perl5/PVE/API2/Nodes.pm'

        if [[ `cat $js|grep -E 'Sensors|CPU'|wc -l` = 0 ]];then
          whiptail --title "Warnning" --msgbox "没有检测到安装，不需要卸载。" 10 60
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
            apt-get install --reinstall pve-manager
            systemctl restart pveproxy
            echo 50
            sleep 1
            echo 100
            sleep 1
          } | whiptail --gauge "正在卸载" 10 60 0
          whiptail --title "Success" --msgbox "卸载成功。" 10 60
        fi
      fi
      chSensors
    ;;
    esac
  fi
