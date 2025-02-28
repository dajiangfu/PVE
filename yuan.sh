#!/bin/bash

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

