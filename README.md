# Hysteria2
hysteria2一键安装(轻量级超低占用)

## 支持系统
- Debian/Ubuntu 系列
- CentOS/RHEL/Rocky/Fedora 系列  
- Alpine Linux 3.15+

## 功能特点
- 支持ACME证书申请和自签证书
- 支持端口跳跃
- 支持自定义节点名称
- 支持修改快捷指令
- 支持IPv4/IPv6
- 自动生成分享链接
- 随机生成UUID密码

## 安装方式

### Bash脚本版本 (推荐新手使用)
- 无需Python环境
- 轻量快速
- 基础功能完整
```bash
wget https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy2.sh -O hy2.sh && chmod 777 hy2.sh && bash hy2.sh
```

### Python脚本版本 (适合进阶用户)
- 需要Python3环境
- 代码结构清晰
- 更易扩展维护
```bash
wget https://raw.githubusercontent.com/heyuecock/hysteria2/main/hy2.py -O hy2.py && python3 hy2.py
```

## 使用说明
1. 安装完成后可使用 `hy2` 命令快速启动
2. 支持以下功能:
   - 安装/卸载
   - 查看配置
   - 修改快捷指令
   - 一键退出

## 客户端支持
- iOS: Shadowrocket
- Android: NekoBox(推荐), Clash Meta, Hiddify
- PC: Nekoray(推荐), Clash Verge, Hiddify

## 免责声明
本程序仅供学习研究使用,请遵守当地法律法规

