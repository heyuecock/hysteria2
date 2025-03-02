#!/bin/bash
[ "$EUID" -ne 0 ] && echo "请使用root用户" && exit 1

# 系统检测优化
check_sys() {
  if [ -f /etc/alpine-release ]; then
    os_type="alpine"
  elif grep -qi "debian\|ubuntu" /etc/os-release; then
    os_type="debian"
  elif grep -qi "centos\|red hat\|fedora" /etc/os-release; then
    os_type="centos"
  else
    echo "不支持的系统" && exit 1
  fi
}

# Alpine专用服务管理函数
alpine_service() {
  case $1 in
    enable)
      rc-update add $2 default 2>/dev/null
      ;;
    start)
      rc-service $2 start 2>/dev/null
      ;;
    restart)
      rc-service $2 restart 2>/dev/null
      ;;
    status)
      rc-service $2 status 2>/dev/null
      ;;
  esac
}

# 安装依赖优化
install_deps() {
  case $os_type in
    alpine)
      echo "正在为Alpine系统安装依赖..."
      apk update
      apk add --no-cache wget curl openssl iptables bash coreutils jq
      # 创建必要符号链接
      [ ! -e /bin/bash ] && ln -sf /usr/bin/bash /bin/bash
      [ ! -e /usr/bin/wget ] && ln -sf /bin/wget /usr/bin/wget
      # 配置持久化iptables
      apk add iptables-legacy iptables-legacy-openrc
      rc-update add iptables default 2>/dev/null
      rc-service iptables start 2>/dev/null
      ;;
    debian)
      apt update && apt install -y wget curl openssl iptables
      ;;
    centos)
      yum install -y wget curl openssl iptables
      ;;
  esac
}

# 端口跳跃配置优化
setup_port_hop() {
  read -p "是否启用端口跳跃(y/n)[n]: " enable_hop
  enable_hop=${enable_hop:-n}
  if [ "$enable_hop" = "y" ]; then
    read -p "起始端口: " start_port
    read -p "结束端口: " end_port
    
    if [ "$start_port" -lt "$end_port" ]; then
      iptables -t nat -A PREROUTING -i eth0 -p udp --dport "$start_port":"$end_port" -j REDIRECT --to-ports "$port"
      
      # Alpine持久化规则
      if [ "$os_type" = "alpine" ]; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        cat > /etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables/rules.v4
EOF
        chmod +x /etc/network/if-pre-up.d/iptables
        
        # 创建OpenRC服务
        cat > /etc/init.d/port-hop <<EOF
#!/sbin/openrc-run
description="Port Hopping Service"

start() {
    ebegin "Starting port hop"
    iptables -t nat -A PREROUTING -i eth0 -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $port
    eend \$?
}
EOF
        chmod +x /etc/init.d/port-hop
        alpine_service enable port-hop
        alpine_service start port-hop
      else
        # systemd配置
        cat > /etc/systemd/system/port-hop.service <<EOF
[Unit]
Description=Port Hopping Service
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t nat -A PREROUTING -i eth0 -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $port
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable port-hop
        systemctl start port-hop
      fi
    else
      echo "起始端口必须小于结束端口"
      return 1
    fi
  fi
}

# 安装Hysteria2优化
install_hy2() {
  mkdir -p /etc/hysteria
  
  # 强制使用备用安装方式
  export FORCE_NO_SYSTEMD=2
  echo "正在下载hysteria2..."
  if ! curl -fsSL https://get.hy2.sh/ | bash; then
    echo "官方脚本安装失败,尝试使用备用方式..."
    
    # 获取最新版本
    latest_version=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r '.tag_name')
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64";;
        aarch64) arch="arm64";;
        armv7l) arch="arm";;
        *) 
          if [ "$os_type" = "alpine" ]; then
            case $(uname -m) in
              x86_64) arch="amd64";;
              aarch64) arch="arm64";;
              armv7*) arch="arm";;
              *) echo "不支持的Alpine架构: $arch" && exit 1;;
            esac
          else
            echo "不支持的架构: $arch" && exit 1
          fi
          ;;
    esac

    if ! wget -q "https://github.com/apernet/hysteria/releases/download/$latest_version/hysteria-linux-$arch" -O /usr/local/bin/hysteria; then
        echo "错误: 下载失败"
        exit 1
    fi
    chmod +x /usr/local/bin/hysteria
  fi

  # 生成配置文件
  gen_config
  
  # 创建OpenRC服务
  if [ "$os_type" = "alpine" ]; then
    cat > /etc/init.d/hysteria-server <<EOF
#!/sbin/openrc-run
description="Hysteria Server Service"
pidfile="/var/run/hysteria-server.pid"

start() {
    ebegin "Starting Hysteria"
    /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml --log-level warn &
    echo \$! > \$pidfile
    eend \$?
}

stop() {
    ebegin "Stopping Hysteria"
    kill \$(cat \$pidfile)
    eend \$?
    rm -f \$pidfile
}
EOF
    chmod +x /etc/init.d/hysteria-server
    alpine_service enable hysteria-server
    alpine_service start hysteria-server
  else
    # systemd配置
    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server
  fi

  # 检查服务状态
  if [ "$os_type" = "alpine" ]; then
    if alpine_service status hysteria-server | grep -q "started"; then
      echo -e "\nHysteria服务已成功启动并设置开机自启\n"
    else
      echo -e "\n警告: Hysteria服务启动失败"
    fi
  else
    if systemctl is-active hysteria-server >/dev/null; then
      echo -e "\nHysteria服务已成功启动并设置开机自启\n"
    else
      echo -e "\n警告: Hysteria服务启动失败"
    fi
  fi
  
  # 创建快捷方式
  echo '#!/bin/bash
wget -q https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy2.sh -O hy2.sh && chmod 777 hy2.sh && bash hy2.sh' > /usr/local/bin/hy2
  chmod +x /usr/local/bin/hy2
}

# 其他函数保持不变...

# 主菜单
menu() {
  echo "1. 安装"
  echo "2. 卸载"
  echo "3. 查看配置"
  echo "4. 修改快捷指令"
  echo "0. 退出"
  read -p "选择: " choice
  
  case $choice in
    1) 
      check_sys && install_deps && install_hy2
      ;;
    2) 
      if [ "$os_type" = "alpine" ]; then
        alpine_service stop hysteria-server
        rc-update del hysteria-server
        rm -f /etc/init.d/hysteria-server
      else
        systemctl stop hysteria-server
        systemctl disable hysteria-server
      fi
      rm -rf /etc/hysteria
      rm -f /usr/local/bin/hy2
      rm -f /usr/local/bin/hysteria
      rm -f hy2.sh
      echo "卸载完成"
      ;;
    3) 
      echo "当前配置:"
      cat /etc/hysteria/config.yaml
      get_share_link
      ;;
    4)
      read -p "请输入新的快捷指令名称[hy2]: " new_name
      new_name=${new_name:-hy2}
      mv /usr/local/bin/hy2 "/usr/local/bin/$new_name"
      echo "快捷指令已修改为: $new_name"
      ;;
    0) echo "已退出" && exit 0 ;;
    *) echo "选项错误" ;;
  esac
}

# 初始化执行
check_sys
menu
