#!/usr/bin/env python3
import os
import sys
import subprocess
from pathlib import Path
import shutil
import uuid
import re

class Hysteria2:
    def __init__(self):
        self.config_dir = Path("/etc/hysteria")
        self.bin_path = Path("/usr/local/bin/hysteria")
        self.recommended_domains = {
            "1": "www.bing.com",
            "2": "www.microsoft.com", 
            "3": "www.apple.com",
            "4": "www.amazon.com",
            "5": "www.cloudflare.com"
        }
        
    def check_root(self):
        return os.geteuid() == 0
        
    def check_sys(self):
        if Path("/etc/os-release").exists():
            with open("/etc/os-release") as f:
                content = f.read().lower()
                if "alpine" in content:
                    return "alpine"
        
        if Path("/etc/issue").exists():
            with open("/etc/issue") as f:
                content = f.read().lower()
                if "debian" in content or "ubuntu" in content:
                    return "debian"
                elif any(x in content for x in ["centos", "red hat", "fedora"]):
                    return "centos"
        
        return None

    def install_deps(self):
        os_type = self.check_sys()
        if not os_type:
            print("不支持的系统")
            sys.exit(1)
        
        try:
            if os_type == "debian":
                subprocess.run("apt update && apt install -y wget curl openssl iptables", shell=True, check=True)
            elif os_type == "centos":
                subprocess.run("yum install -y wget curl openssl iptables", shell=True, check=True)
            elif os_type == "alpine":
                # 更新包索引
                subprocess.run("apk update", shell=True, check=True)
                # 安装基础依赖
                subprocess.run("apk add wget curl openssl iptables bash coreutils", shell=True, check=True)
                # 确保bash可用
                if not Path("/bin/bash").exists():
                    subprocess.run("ln -sf /bin/bash /bin/sh", shell=True, check=True)
        except subprocess.CalledProcessError as e:
            print(f"安装依赖失败: {e}")
            sys.exit(1)

    def setup_port_hop(self, port):
        enable_hop = input("是否启用端口跳跃(y/n)[n]: ").lower() or "n"
        if enable_hop == "y":
            while True:
                try:
                    start_port = int(input("起始端口: "))
                    end_port = int(input("结束端口: "))
                    if 1 <= start_port < end_port <= 65535:
                        break
                    print("端口范围: 1-65535, 起始端口必须小于结束端口")
                except ValueError:
                    print("请输入有效的端口号")
            
            try:
                subprocess.run(f"iptables -t nat -A PREROUTING -i eth0 -p udp --dport {start_port}:{end_port} -j REDIRECT --to-ports {port}", shell=True, check=True)
                print(f"端口跳跃已配置: {start_port}-{end_port} -> {port}")
                
                # 为Alpine添加iptables持久化
                os_type = self.check_sys()
                if os_type == "alpine":
                    subprocess.run("apk add iptables-persistent", shell=True, check=True)
                    subprocess.run("/etc/init.d/iptables save", shell=True, check=True)
            
            except subprocess.CalledProcessError as e:
                print(f"配置端口跳跃失败: {e}")
                return False
            
            return True
        
    def install(self):
        self.config_dir.mkdir(exist_ok=True)
        
        # 下载并安装hysteria2
        print("正在下载hysteria2...")
        try:
            # 使用官方安装脚本
            if subprocess.run("curl -fsSL https://get.hy2.sh/ | bash", shell=True).returncode != 0:
                print("官方脚本安装失败,尝试使用备用方式...")
                
                # 获取最新版本
                latest_version = subprocess.check_output(
                    "curl -s 'https://api.github.com/repos/apernet/hysteria/releases/latest' | grep -Po '\"tag_name\": \"\\K.*?(?=\")'",
                    shell=True
                ).decode().strip()
                
                # 确定架构
                arch = subprocess.check_output("uname -m", shell=True).decode().strip()
                arch_map = {
                    "x86_64": "amd64",
                    "aarch64": "arm64",
                    "armv7l": "arm"
                }
                
                if arch not in arch_map:
                    os_type = self.check_sys()
                    if os_type == "alpine":
                        # Alpine特殊架构处理
                        if arch.startswith("armv7"):
                            arch = "arm"
                        elif arch == "x86_64":
                            arch = "amd64"
                        elif arch == "aarch64":
                            arch = "arm64"
                        else:
                            raise Exception(f"不支持的Alpine架构: {arch}")
                    else:
                        raise Exception(f"不支持的架构: {arch}")
                else:
                    arch = arch_map[arch]
                
                # 下载二进制文件
                download_url = f"https://github.com/apernet/hysteria/releases/download/{latest_version}/hysteria-linux-{arch}"
                if subprocess.run(f"wget -q '{download_url}' -O /usr/local/bin/hysteria", shell=True).returncode != 0:
                    raise Exception("Download failed")
                    
        except Exception as e:
            print(f"安装失败: {e}")
            sys.exit(1)

        # 检查二进制文件位置
        binary_paths = ["/usr/local/bin/hysteria", "/usr/bin/hysteria"]
        binary_path = None
        for path in binary_paths:
            if os.path.isfile(path):
                binary_path = path
                break
                
        if not binary_path:
            print("找不到 hysteria 二进制文件")
            sys.exit(1)

        # 验证二进制文件
        try:
            subprocess.check_call([binary_path, "version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            print("hysteria2 验证失败")
            print(f"请尝试手动运行: {binary_path} version")
            sys.exit(1)

        # 确保二进制文件在 /usr/local/bin
        if binary_path != "/usr/local/bin/hysteria":
            shutil.copy2(binary_path, "/usr/local/bin/hysteria")
            os.chmod("/usr/local/bin/hysteria", 0o755)

        print("hysteria2 安装成功")
        
        # 创建并配置systemd服务
        service_path = Path("/etc/systemd/system/hysteria-server.service") 
        service_content = """[Unit]
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
"""
        service_path.write_text(service_content)
        service_path.chmod(0o644)  # 设置正确的权限

        # 重载systemd并启用服务
        subprocess.run("systemctl daemon-reload", shell=True)
        subprocess.run("systemctl enable hysteria-server", shell=True)
        
        # 启动服务并检查状态
        subprocess.run("systemctl start hysteria-server", shell=True)
        
        # 检查服务状态
        try:
            subprocess.check_call("systemctl is-active hysteria-server >/dev/null 2>&1", shell=True)
            print("\nHysteria服务已成功启动并设置开机自启\n")
        except subprocess.CalledProcessError:
            print("\n警告: Hysteria服务启动失败")
            print("请使用以下命令查看详细错误信息:")
            print("systemctl status hysteria-server")
            print("journalctl -u hysteria-server")
        
        # 创建快捷方式
        with open("/usr/local/bin/hy2", "w") as f:
            f.write("#!/bin/bash\nwget -q https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy2.py -O hy2.py && python3 hy2.py")
        os.chmod("/usr/local/bin/hy2", 0o755)
        print("已创建快捷命令 'hy2', 可直接在终端使用")
        
        # 生成配置
        self.gen_config()
        
    def gen_self_cert(self, domain="www.bing.com"):
        cert_dir = Path("/etc/ssl/private")
        cert_dir.mkdir(parents=True, exist_ok=True)
        
        cmd = f"""
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "{cert_dir}/{domain}.key" \
        -out "{cert_dir}/{domain}.crt" \
        -subj "/CN={domain}" -days 36500
        """
        try:
            subprocess.run(cmd, shell=True, executable='/bin/bash', check=True, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            print("证书生成失败")
            return None, None
        
        # 设置正确的权限
        os.chmod(f"{cert_dir}/{domain}.key", 0o644)
        os.chmod(f"{cert_dir}/{domain}.crt", 0o644)
        
        return f"{cert_dir}/{domain}.crt", f"{cert_dir}/{domain}.key"
        
    def apply_acme_cert(self, domain, email):
        # 安装acme.sh
        subprocess.run(f"curl https://get.acme.sh | sh -s email={email}", shell=True)
        
        # 申请证书
        subprocess.run([
            "~/.acme.sh/acme.sh", "--issue",
            "-d", domain,
            "--standalone",
            "-k", "ec-256"
        ], shell=True)
        
        # 安装证书
        cert_dir = Path("/etc/ssl/private")
        cert_dir.mkdir(parents=True, exist_ok=True)
        
        subprocess.run([
            "~/.acme.sh/acme.sh", "--installcert",
            "-d", domain,
            "--key-file", f"{cert_dir}/cert.key",
            "--fullchain-file", f"{cert_dir}/cert.pem",
            "--ecc"
        ], shell=True)
        
        return f"{cert_dir}/cert.pem", f"{cert_dir}/cert.key"
    
    def setup_cert(self):
        print("证书配置:")
        print("1. 使用自签证书")
        print("2. 使用ACME申请证书(需要域名)")
        cert_choice = input("选择[1]: ") or "1"
        
        if cert_choice == "2":
            domain = input("域名: ")
            email = input("邮箱: ")
            cert_path, key_path = self.apply_acme_cert(domain, email)
        else:  # 默认使用自签证书
            print("\n推荐域名列表:")
            for key, domain in self.recommended_domains.items():
                print(f"{key}. {domain}")
            print("6. 自定义域名")
            
            domain_choice = input("\n请选择[1]: ") or "1"
            
            if domain_choice == "6":
                domain = input("请输入自定义域名: ") or "www.bing.com"
            else:
                domain = self.recommended_domains.get(domain_choice, "www.bing.com")
                
            cert_path, key_path = self.gen_self_cert(domain)
            
            if not cert_path or not key_path:
                print("证书生成失败，使用默认域名重试")
                cert_path, key_path = self.gen_self_cert()
        
        # 更新配置文件中的证书路径
        config_path = self.config_dir / "config.yaml"
        if config_path.exists():
            config_text = config_path.read_text()
            config_text = re.sub(r'cert: .*', f'cert: {cert_path}', config_text)
            config_text = re.sub(r'key: .*', f'key: {key_path}', config_text)
            config_path.write_text(config_text)
            
        return cert_path, key_path
    
    def gen_config(self):
        while True:
            try:
                port = input("端口(1-65535)[443]: ") or "443"
                port = int(port)
                if 1 <= port <= 65535:
                    break
                print("端口范围: 1-65535")
            except ValueError:
                print("请输入有效的端口号(1-65535)")
                
        default_password = str(uuid.uuid4())
        passwd = input(f"密码(回车使用随机生成的UUID) [{default_password}]: ") or default_password
        
        # 使用更完整的配置模板
        config = f"""listen: :{port}

auth:
  type: password
  password: {passwd}

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
"""
        config_file = self.config_dir / "config.yaml"
        config_file.write_text(config)
        config_file.chmod(0o600)
        
        # 设置证书和端口跳跃
        self.setup_cert()
        self.setup_port_hop(port)
        
        # 添加命名功能
        node_name = input("请输入节点名称[hysteria2]: ") or "hysteria2"
        
        # 生成分享链接
        try:
            # 获取服务器IP
            server_ip = subprocess.check_output("curl -s4 ip.sb || curl -s6 ip.sb", shell=True).decode().strip()
            if not server_ip:
                raise Exception("Empty IP")
        except:
            print("警告: 获取服务器IP失败")
            server_ip = "获取IP失败,请手动替换此处"
            
        print("\n分享链接:")
        print(f"hysteria2://{passwd}@{server_ip}:{port}?alpn=h3&insecure=1#{node_name}")
        
    def uninstall(self):
        subprocess.run("systemctl stop hysteria-server 2>/dev/null", shell=True)
        
        if Path("/etc/systemd/system/port-hop.service").exists():
            subprocess.run("systemctl stop port-hop 2>/dev/null", shell=True)
            subprocess.run("systemctl disable port-hop 2>/dev/null", shell=True)
            subprocess.run("rm -f /etc/systemd/system/port-hop.service", shell=True)
        
        subprocess.run("rm -rf /etc/hysteria", shell=True)
        subprocess.run("rm -f /usr/local/bin/hy2", shell=True)
        subprocess.run("rm -f /usr/local/bin/hysteria", shell=True)
        subprocess.run("rm -f hy2.py", shell=True)  # 删除下载的脚本
        subprocess.run("rm -f /etc/systemd/system/hysteria-server.service", shell=True)
        subprocess.run("systemctl daemon-reload", shell=True)
        subprocess.run("iptables -t nat -F", shell=True)
        print("卸载完成")

    def check_dependencies(self):
        required = ['curl', 'openssl', 'iptables']
        for cmd in required:
            if not shutil.which(cmd):
                print(f"缺少依赖: {cmd}")
                return False
        return True

def main():
    if not Hysteria2().check_root():
        print("需要root权限")
        sys.exit(1)
        
    print("1. 安装\n2. 卸载\n3. 查看配置\n4. 修改快捷指令\n0. 退出")
    choice = input("选择: ")
    
    hy2 = Hysteria2()
    if choice == "1":
        hy2.install_deps()
        hy2.install()
    elif choice == "2":
        hy2.uninstall()
    elif choice == "3":
        try:
            config_file = hy2.config_dir / "config.yaml"
            print("\n配置文件内容:")
            print(config_file.read_text())
            
            # 从配置文件中提取信息
            config_text = config_file.read_text()
            
            # 提取端口
            port_match = re.search(r'listen: :(\d+)', config_text)
            port = port_match.group(1) if port_match else "443"
            
            # 提取密码
            passwd_match = re.search(r'password: (.+)', config_text)
            passwd = passwd_match.group(1) if passwd_match else ""
            
            # 获取服务器IP
            try:
                server_ip = subprocess.check_output("curl -s4 ip.sb || curl -s6 ip.sb", shell=True).decode().strip()
                if not server_ip:
                    raise Exception("Empty IP")
            except:
                print("警告: 获取服务器IP失败")
                server_ip = "获取IP失败,请手动替换此处"
            
            # 显示分享链接
            print("\n分享链接:")
            print(f"hysteria2://{passwd}@{server_ip}:{port}?alpn=h3&insecure=1#hysteria2")
            
        except FileNotFoundError:
            print("配置文件不存在")
        except Exception as e:
            print(f"读取配置文件失败: {e}")
    elif choice == "4":
        new_name = input("请输入新的快捷指令名称[hy2]: ") or "hy2"
        old_path = Path("/usr/local/bin/hy2")
        new_path = Path(f"/usr/local/bin/{new_name}")
        
        if old_path.exists():
            old_path.rename(new_path)
            print(f"快捷指令已修改为: {new_name}")
        else:
            with open(new_path, "w") as f:
                f.write("#!/bin/bash\nwget -q https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy2.py -O hy2.py && python3 hy2.py")
            new_path.chmod(0o755)
            print(f"已创建新的快捷指令: {new_name}")
    elif choice == "0":
        print("已退出")
        sys.exit(0)
    else:
        print("选项错误")

if __name__ == "__main__":
    main()
