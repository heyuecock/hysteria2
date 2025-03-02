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
    stop)
      rc-service $2 stop 2>/dev/null
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
      ;;
    debian)
      echo "正在为Debian/Ubuntu系统安装依赖..."
      apt update && apt install -y wget curl openssl iptables
      ;;
    centos)
      echo "正在为CentOS系统安装依赖..."
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
        # 原有systemd配置
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

  # 下载hysteria2二进制文件
  echo "正在下载hysteria2..."
  if ! curl -fsSL https://get.hy2.sh/ | bash; then
    echo "官方脚本安装失败,尝试使用备用方式..."
    
    # 备用下载方式
    latest_version=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
    if ! wget -q "https://github.com/apernet/hysteria/releases/download/$latest_version/hysteria-linux-$arch" -O /usr/local/bin/hysteria; then
        echo "错误: 下载失败"
        echo "请尝试手动下载:"
        echo "1. 访问 https://github.com/apernet/hysteria/releases/latest"
        echo "2. 下载对应架构的文件并重命名为 hysteria"
        echo "3. 将文件放置到 /usr/local/bin/hysteria"
        exit 1
    fi
  fi

  chmod +x /usr/local/bin/hysteria

  # 生成配置
  gen_config
  
  # 创建服务
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
    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service
Documentation=https://hysteria.network/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server
  fi

  # 检查服务状态
  if [ "$os_type" = "alpine" ]; then
    if alpine_service status hysteria-server >/dev/null 2>&1; then
      echo -e "\nHysteria服务已成功启动并设置开机自启\n"
    else
      echo -e "\n警告: Hysteria服务启动失败"
      echo "请查看日志: cat /var/log/hysteria-server.log"
    fi
  else
    if systemctl is-active hysteria-server >/dev/null 2>&1; then
      echo -e "\nHysteria服务已成功启动并设置开机自启\n"
    else
      echo -e "\n警告: Hysteria服务启动失败"
      echo "请使用以下命令查看详细错误信息:"
      echo "systemctl status hysteria-server"
      echo "journalctl -u hysteria-server"
    fi
  fi
  
  # 创建快捷方式
  echo '#!/bin/bash
wget -q https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy2.sh -O hy2.sh && chmod 777 hy2.sh && bash hy2.sh' > /usr/local/bin/hy2
  chmod +x /usr/local/bin/hy2
  
  exit 0
}

# 生成自签证书
gen_self_cert() {
  domain=${1:-"www.bing.com"}
  mkdir -p /etc/ssl/private
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "/etc/ssl/private/$domain.key" \
    -out "/etc/ssl/private/$domain.crt" \
    -subj "/CN=$domain" -days 36500 2>/dev/null

  if [ $? -ne 0 ]; then
    echo "证书生成失败"
    return 1
  fi
  chmod 644 "/etc/ssl/private/$domain.key" "/etc/ssl/private/$domain.crt"
}

# ACME申请证书
apply_acme_cert() {
  domain=$1
  email=$2
  
  # 安装acme.sh
  curl https://get.acme.sh | sh -s email=$email
  source ~/.bashrc
  
  # 申请证书
  ~/.acme.sh/acme.sh --issue -d $domain --standalone -k ec-256
  
  # 安装证书
  ~/.acme.sh/acme.sh --installcert -d $domain \
    --key-file /etc/ssl/private/cert.key \
    --fullchain-file /etc/ssl/private/cert.pem \
    --ecc
}

# 证书配置
setup_cert() {
  echo "证书配置:"
  echo "1. 使用自签证书"
  echo "2. 使用ACME申请证书(需要域名)"
  read -p "选择[1]: " cert_choice
  
  case $cert_choice in
    2)
      read -p "域名: " domain
      read -p "邮箱: " email
      apply_acme_cert "$domain" "$email"
      cert_path="/etc/ssl/private/cert.pem"
      key_path="/etc/ssl/private/cert.key"
      ;;
    1|"")
      echo "推荐域名列表:"
      echo "1. www.bing.com"
      echo "2. www.microsoft.com"
      echo "3. www.apple.com"
      echo "4. www.amazon.com"
      echo "5. www.cloudflare.com"
      echo "6. 自定义域名"
      
      read -p "请选择[1]: " domain_choice
      case $domain_choice in
        1|"") domain="www.bing.com" ;;
        2) domain="www.microsoft.com" ;;
        3) domain="www.apple.com" ;;
        4) domain="www.amazon.com" ;;
        5) domain="www.cloudflare.com" ;;
        6) 
          read -p "请输入自定义域名: " domain
          [ -z "$domain" ] && domain="www.bing.com"
          ;;
        *) domain="www.bing.com" ;;
      esac
      
      gen_self_cert "$domain"
      cert_path="/etc/ssl/private/$domain.crt"
      key_path="/etc/ssl/private/$domain.key" 
      ;;
    *)
      echo "选项错误,使用默认选项1"
      gen_self_cert "www.bing.com"
      cert_path="/etc/ssl/private/www.bing.com.crt"
      key_path="/etc/ssl/private/www.bing.com.key"
      ;;
  esac
  
  # 更新配置文件中的证书路径
  sed -i "s|cert: /etc/ssl/cert.pem|cert: $cert_path|" /etc/hysteria/config.yaml
  sed -i "s|key: /etc/ssl/key.pem|key: $key_path|" /etc/hysteria/config.yaml
}

# 生成UUID
generate_uuid() {
    if command -v uuidgen > /dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# 生成配置
gen_config() {
    while true; do
        read -p "端口(1-65535)[443]: " port
        port=${port:-443}
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        else
            echo "端口范围: 1-65535"
        fi
    done
    
    default_password=$(generate_uuid)
    read -p "密码(回车使用随机生成的UUID) [${default_password}]: " passwd
    passwd=${passwd:-$default_password}
    
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$port

auth:
  type: password
  password: $passwd

tls:
  cert: /etc/ssl/cert.pem
  key: /etc/ssl/key.pem

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
  
quic:
  initStreamReceiveWindow: 8388608 
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

    setup_cert
    setup_port_hop
    
    read -p "请输入节点名称[hysteria2]: " node_name
    node_name=${node_name:-hysteria2}
    
    if [ -f "/etc/hysteria/config.yaml" ]; then
        server_ip=$(curl -s4 ip.sb || curl -s6 ip.sb)
        if [ -z "$server_ip" ]; then
            echo "警告: 获取服务器IP失败"
            server_ip="获取IP失败,请手动替换此处"
        fi
        
        echo -e "\n分享链接:"
        echo "hysteria2://${passwd}@${server_ip}:${port}?alpn=h3&insecure=1#${node_name}"
        echo
    fi
}

# 在check_service_status函数后添加新函数
clean_hysteria_process() {
  # 查找hysteria进程
  local pids=$(pgrep hysteria)
  if [ -n "$pids" ]; then
    echo "正在清理hysteria进程..."
    for pid in $pids; do
      kill -9 $pid 2>/dev/null
    done
    sleep 1
  fi
  
  # 二次确认是否还有残留进程
  if pgrep hysteria >/dev/null; then
    echo "警告: 仍有hysteria进程残留"
    return 1
  fi
  return 0
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
      read -p "确认要卸载Hysteria2吗?(y/n)[n]: " confirm
      confirm=${confirm:-n}
      if [ "$confirm" != "y" ]; then
        echo "已取消卸载"
        return
      fi
      
      echo "开始卸载Hysteria2..."
      
      # 停止服务
      if [ "$os_type" = "alpine" ]; then
        alpine_service stop hysteria-server
        alpine_service stop port-hop
        rc-update del hysteria-server 2>/dev/null
        rc-update del port-hop 2>/dev/null
      else
        systemctl stop hysteria-server 2>/dev/null
        systemctl stop port-hop 2>/dev/null
        systemctl disable hysteria-server 2>/dev/null
        systemctl disable port-hop 2>/dev/null
      fi
      
      # 清理进程
      clean_hysteria_process
      
      # 清理文件
      rm -rf /etc/hysteria
      rm -f /usr/local/bin/hy2
      rm -f /usr/local/bin/hysteria
      rm -f hy2.sh
      rm -f /etc/systemd/system/hysteria-server.service
      rm -f /etc/init.d/hysteria-server
      rm -f /etc/init.d/port-hop
      
      # 重载服务
      if [ "$os_type" = "alpine" ]; then
        rc-service iptables restart 2>/dev/null
      else  
        systemctl daemon-reload
      fi
      
      # 清理iptables规则
      iptables -t nat -F
      
      # 验证卸载结果
      if pgrep hysteria >/dev/null || [ -d "/etc/hysteria" ] || [ -f "/usr/local/bin/hysteria" ]; then
        echo "警告: 卸载可能不完整,请检查是否有残留"
        exit 1
      else
        echo "Hysteria2已完全卸载"
      fi
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
wget -q https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy2.sh -O hy2.sh && chmod 777 hy2.sh && bash hy2.sh' > "/usr/local/bin/$new_name"
        chmod +x "/usr/local/bin/$new_name"
        echo "已创建新的快捷指令: $new_name"
      fi
      ;;
    0) echo "已退出" && exit 0 ;;
    *) echo "选项错误" ;;
  esac
}

menu
