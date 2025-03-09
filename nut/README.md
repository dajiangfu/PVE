更新替换此目录中文件后需要执行的命令

chown root:nut /etc/nut/upssched-cmd
chmod 750 /etc/nut/upssched-cmd

systemctl restart nut-server
systemctl restart nut-server
systemctl restart nut-monitor

查看 nut 服务状态
systemctl status nut-server
systemctl status nut-client
systemctl status nut-monitor
upsc tgbox850@localhost

systemctl status nut-upssched

