#!/bin/bash
[ "$EUID" -ne 0 ] && echo "请使用root用户" && exit 1

# 系统检测
check_sys() {
  if grep -qi "debian\|ubuntu" /etc/issue; then
    os_type="debian"
  elif grep -qi "centos\|red hat\|fedora" /etc/issue; then
    os_type="centos"  
  elif grep -qi "alpine" /etc/os-release; then
    os_type="alpine"
  else
    echo "不支持的系统" && exit 1
  fi
}

# 安装依赖
install_deps() {
  case $os_type in
    debian)
      apt update && apt install -y wget curl openssl iptables
      ;;
    centos)  
      yum install -y wget curl openssl iptables
      ;;
    alpine)
      # 更新包索引
      apk update
      # 安装基础依赖
      apk add wget curl openssl iptables bash coreutils
      # 确保bash可用
      if [ ! -e /bin/bash ]; then
        ln -sf /bin/bash /bin/sh
      fi
      ;;
  esac
}

# 配置端口跳跃
setup_port_hop() {
  read -p "是否启用端口跳跃(y/n)[n]: " enable_hop
  enable_hop=${enable_hop:-n}  # 设置默认值为n
  if [ "$enable_hop" = "y" ]; then
    read -p "起始端口: " start_port
    read -p "结束端口: " end_port
    
    if [ "$start_port" -lt "$end_port" ]; then
      iptables -t nat -A PREROUTING -i eth0 -p udp --dport "$start_port":"$end_port" -j REDIRECT --to-ports "$port"
      echo "端口跳跃已配置: $start_port-$end_port -> $port"
      
      # 为Alpine添加iptables持久化
      if [ "$os_type" = "alpine" ]; then
        # 安装iptables-persistent
        apk add iptables-persistent
        # 保存规则
        /etc/init.d/iptables save
      fi
      
      # 创建开机自启服务
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
    else
      echo "起始端口必须小于结束端口"
      return 1
    fi
  fi
}

# 安装Hysteria2
install_hy2() {
  mkdir -p /etc/hysteria
  
  # 下载hysteria2二进制文件
  echo "正在下载hysteria2..."
  if ! curl -fsSL https://get.hy2.sh/ | bash; then
    echo "官方脚本安装失败,尝试使用备用方式..."
    
    # 备用下载方式
    latest_version=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64";;
        aarch64) arch="arm64";;
        armv7l) arch="arm";;
        *) 
          if [ "$os_type" = "alpine" ]; then
            # Alpine可能使用不同的架构名称
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
        echo "请尝试手动下载:"
        echo "1. 访问 https://github.com/apernet/hysteria/releases/latest"
        echo "2. 下载对应架构的文件并重命名为 hysteria"
        echo "3. 将文件放置到 /usr/local/bin/hysteria"
        exit 1
    fi
  fi

  # 检查二进制文件位置
  if [ -f "/usr/local/bin/hysteria" ]; then
    binary_path="/usr/local/bin/hysteria"
  elif [ -f "/usr/bin/hysteria" ]; then
    binary_path="/usr/bin/hysteria"
  else
    echo "找不到 hysteria 二进制文件"
    exit 1
  fi

  # 验证二进制文件
  if ! $binary_path version >/dev/null 2>&1; then
    echo "hysteria2 验证失败"
    echo "请尝试手动运行: $binary_path version"
    exit 1
  fi

  # 确保二进制文件在 /usr/local/bin
  if [ "$binary_path" != "/usr/local/bin/hysteria" ]; then
    cp "$binary_path" "/usr/local/bin/hysteria"
    chmod +x "/usr/local/bin/hysteria"
  fi

  echo "hysteria2 安装成功"
  echo "已创建快捷命令 'hy2', 可直接在终端使用"
  
  # 生成配置
  gen_config
  
  # 创建systemd服务
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

  # 设置正确的权限
  chmod 644 /etc/systemd/system/hysteria-server.service
  
  # 重载systemd并启用服务
  systemctl daemon-reload
  systemctl enable hysteria-server
  
  # 启动服务
  systemctl start hysteria-server
  
  # 检查服务状态
  if systemctl is-active hysteria-server >/dev/null 2>&1; then
    echo -e "\nHysteria服务已成功启动并设置开机自启\n"
  else
    echo -e "\n警告: Hysteria服务启动失败"
    echo "请使用以下命令查看详细错误信息:"
    echo "systemctl status hysteria-server"
    echo "journalctl -u hysteria-server"
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

  # 添加错误检查
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
    1|"")  # 默认选项1
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
        # 如果没有uuidgen命令,用其他方式生成UUID
        cat /proc/sys/kernel/random/uuid
    fi
}

# 生成配置
gen_config() {
    # 先获取所有用户输入
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
    
    # 生成基础配置文件
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

    # 设置证书
    setup_cert
    
    # 设置端口跳跃
    setup_port_hop
    
    # 获取节点名称
    read -p "请输入节点名称[hysteria2]: " node_name
    node_name=${node_name:-hysteria2}
    
    # 生成分享链接
    if [ -f "/etc/hysteria/config.yaml" ]; then
        # 获取服务器IP
        server_ip=$(curl -s4 ip.sb || curl -s6 ip.sb)
        if [ -z "$server_ip" ]; then
            echo "警告: 获取服务器IP失败"
            server_ip="获取IP失败,请手动替换此处"
        fi
        
        echo -e "\n分享链接:"
        echo "hysteria2://${passwd}@${server_ip}:${port}?alpn=h3&insecure=1#${node_name}"
        echo  # 添加空行
    fi
}

# 添加新函数用于生成分享链接
get_share_link() {
  if [ -f "/etc/hysteria/config.yaml" ]; then
    local port=$(grep "listen:" /etc/hysteria/config.yaml | awk -F':' '{print $3}')
    local passwd=$(grep "password:" /etc/hysteria/config.yaml | awk '{print $2}')
    local server_ip=$(curl -s4 ip.sb || curl -s6 ip.sb)
    
    if [ -z "$server_ip" ]; then
      server_ip="获取IP失败,请手动替换此处"
    fi
    
    echo -e "\n分享链接:"
    echo "hysteria2://${passwd}@${server_ip}:${port}?alpn=h3&insecure=1#hysteria2"
    echo  # 添加空行
  else
    echo "配置文件不存在"
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
      systemctl stop hysteria-server 2>/dev/null
      if [ -f "/etc/systemd/system/port-hop.service" ]; then
        systemctl stop port-hop 2>/dev/null
        systemctl disable port-hop 2>/dev/null
        rm -f /etc/systemd/system/port-hop.service
      fi
      rm -rf /etc/hysteria
      rm -f /usr/local/bin/hy2
      rm -f /usr/local/bin/hysteria
      rm -f hy2.sh
      rm -f /etc/systemd/system/hysteria-server.service
      systemctl daemon-reload
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
