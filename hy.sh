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
      rc-update add $2 默认 2>/dev/null
      ;;
    start)
      rc-service $2 start 2>/dev/null
      ;;
    restart)
      rc-service $2 restart 2>/dev/null
      ;;
  esac
}

# 安装依赖优化
install_deps() {
  case $os_type in
    alpine)
      apk update
      apk add --no-cache wget curl openssl iptables iptables-openrc bash coreutils jq
      # 创建必要符号链接
      [ ! -e /bin/bash ] && ln -sf /usr/bin/bash /bin/bash
      [ ! -e /usr/bin/wget ] && ln -sf /bin/wget /usr/bin/wget
      # 配置持久化iptables
      rc-update add iptables default 2>/dev/null
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
        iptables-save > /etc/iptables/rules.v4
        echo "iptables -t nat -A PREROUTING -i eth0 -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $port" >> /etc/network/if-pre-up.d/iptables
        chmod +x /etc/network/if-pre-up.d/iptables
      fi
      
      # 创建OpenRC服务
      if [ "$os_type" = "alpine" ]; then
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
        # 原有systemd配置...
      fi
    fi
  fi
}

# 安装Hysteria2优化
install_hy2() {
  # 架构检测优化
  case $(uname -m) in
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

  # OpenRC服务配置
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
  else
    # 原有systemd配置...
  fi
}

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
      rc-service hysteria-server stop 2>/dev/null
      if [ -f "/etc/init.d/port-hop" ]; then
        rc-service port-hop stop 2>/dev/null
        rc-update del port-hop 2>/dev/null
        rm -f /etc/init.d/port-hop
      fi
      rm -rf /etc/hysteria
      rm -f /usr/local/bin/hy2
      rm -f /usr/local/bin/hysteria
      rm -f hy.sh
      rm -f /etc/init.d/hysteria-server
      rc-update del hysteria-server 2>/dev/null
      iptables -t nat -F
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
      if [ -f "/usr/local/bin/hy2" ]; then
        mv /usr/local/bin/hy2 "/usr/local/bin/$new_name"
        echo "快捷指令已修改为: $new_name"
      else
        echo '#!/bin/bash
wget -q https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy.sh -O hy.sh && chmod 777 hy.sh && bash hy.sh' > "/usr/local/bin/$new_name"
        chmod +x "/usr/local/bin/$new_name"
        echo "已创建新的快捷指令: $new_name"
      fi
      ;;
    0) echo "已退出" && exit 0 ;;
    *) echo "选项错误" ;;
  esac
}

menu
