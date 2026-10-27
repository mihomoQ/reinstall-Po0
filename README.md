# reinstall-Po0

面向 Po0 内网环境的系统重装脚本，基于 [bin456789/reinstall](https://github.com/bin456789/reinstall)，保留上游多发行版选择及 GPL-3.0 许可证。

**当前为适配开发版，已在一个 Po0 x86_64/BIOS 实例完成 Debian 12 的真实重装、首次启动、SSH 与 APT 更新验证。** 其他发行版和硬件路径尚未完成实机验证。具体执行路径与边界见 [实机测试记录](docs/live-test-2026-10-27.md)。

## Po0 上的变化

- 不再访问公网服务判断地区或联网状态，不再因公网探测失败删除 IP、路由或禁用 DHCP。
- 安装环境按 MAC 找到网卡并请求 DHCP，保留获得的内网地址、网关、DNS；公网映射地址不写入网卡。
- DHCP 超时时可在安装环境临时使用原网络配置，目标系统仍配置为 DHCP。原系统实际 DNS 随安装文件保存，不使用公共 DNS 回退。
- 默认镜像为 `http://mirrors.tencentyun.com`；下载和目标系统的软件源接入统一 URL 映射，Debian security 单独处理。
- 安装过程只提供 SSH/screen 日志，删除 Web 日志服务、页面、`--web-port` / `--http-port` 及其专用依赖。
- 使用完整本地 bundle。辅助脚本、Debian preseed 和配置随 initrd 携带，经过 Alpine `switch_root` 后仍保留，不从上游 GitHub/CNB 拉取另一版本脚本。
- Linux 内核、initrd、辅助文件及 Linux EFI GRUB 下载/打包成功后才替换现有重装引导文件。保留磁盘识别、引导模式、架构和格式检查。

这不是原 Po0 面板镜像的复制工具，不会把厂商旧 Python、全部调优参数或某台实例的 IP/MAC 固定写入新系统。

## 安装资源状态

2026-10-27 在一个 Po0 实例上检查的结果如下。HEAD 成功只说明对应资源可访问，不代表完整安装通过。

| 路径 | 当前观察 |
|---|---|
| Debian 12 常规安装 | 已完成真实重装、首次启动、公钥 SSH 和内网基础源/updates/security 更新验证 |
| Debian 13 | Release 文件可访问；未进行完整安装 |
| Alpine 3.24 | amd64 virt 内核、initramfs 和软件源可访问；未进行完整安装 |
| AlmaLinux 9 | 默认 GenericCloud 云镜像可访问；未进行完整安装，不保证固定到 9.5 |
| Ubuntu 22.04 / 24.04 | 软件源可访问，默认 `ubuntu-cloud-images` 路径为 404；需要 `--img` 或镜像映射 |
| Debian `--ci` | 默认 `debian-cdimage` 路径为 404；需要 `--img` 或镜像映射 |
| 其他上游发行版 | 保留入口，需要逐一验证镜像、软件源及安装流程 |

不能简单把“国内镜像”视为“Po0 可达镜像”。未匹配的用户 URL 会原样使用；不存在的内网资源会报错，不会自动退回已知不可达的公网镜像。

## 获取完整文件

不能只下载 `reinstall.sh`。在能够访问 GitHub 的电脑上克隆仓库或下载完整源码，保留目录结构，再通过 SCP/SFTP 传到 Po0。

也可以在电脑上构建压缩包：

```sh
python3 tools/build-bundle.py
```

生成 `dist/reinstall-Po0.tar.gz`。包内有 `SHA256SUMS`，脚本启动时会校验；构建器不包含本地 `po0.conf`、`po0-mirrors.conf`、密钥或机器记录。默认包校验覆盖发行的代码与文档，不能替代对发布来源的信任。

## 使用

解压或上传完整目录后，从该目录运行。以下命令会准备重装，之后重启将清空目标系统盘；不是只读检查。

```sh
sudo bash reinstall.sh debian 12 --ssh-key /root/.ssh/authorized_keys
sudo bash reinstall.sh debian 13 --ssh-key /root/.ssh/authorized_keys
sudo bash reinstall.sh almalinux 9 --ssh-key /root/.ssh/authorized_keys
```

保留上游的用户名、密码、公钥、SSH 端口、`--hold`、`reset`、云镜像和 DD 等入口。原始系统/版本列表及其他选项见 [上游用法备份](README.upstream.md)；其中单文件下载、Web 日志和公网镜像说明不适用于本分支。

`--hold 1` 仍会准备引导，供后续进入安装环境检查，不是只读模式。本轮已验证该模式下的安装器网络、SSH，以及重启回原系统。

重启前可用以下命令取消已准备的重装：

```sh
sudo bash reinstall.sh reset
```

安装期间通过指定的 SSH 端口登录。Debian/Kali 可查看 `tail -f /var/log/syslog` 或 `screen -x root/`；Alpine 中间环境可查看 `tail -f /reinstall.log`。登录信息由准备阶段输出。

## 自定义内部资源

主镜像需要变化时，复制 `po0.conf.example` 为 `po0.conf`。`PO0_MIRROR_BASE` 只能是 HTTP 协议、主机和可选端口，不包含仓库路径；Debian 安装器的软件源路径使用 HTTP，因此此项不接受 HTTPS-only 源。单独的镜像 URL 和下方前缀映射可以使用 HTTPS。

单独覆盖缺失的云镜像目录时，复制 `po0-mirrors.conf.example` 为 `po0-mirrors.conf`，每行两个 URL 前缀，以空格或制表符分隔，第一条匹配生效。例如将完整的 Ubuntu 云镜像目录放在你控制、且 Po0 能访问的服务上：

```text
https://mirror.nju.edu.cn/ubuntu-cloud-images/ http://YOUR-MIRROR:8080/ubuntu-cloud-images/
```

这里的主机和端口只是占位示例，不表示该端口已经放通。映射文件使用原始 URL 前缀；映射不会执行 shell 表达式，也不自动寻找公网代理。

也可以为某次安装直接指定可达镜像：

```sh
sudo bash reinstall.sh ubuntu 24.04 --img 'http://YOUR-MIRROR:PORT/ubuntu-24.04-server-cloudimg-amd64.img' --ssh-key /root/.ssh/authorized_keys
```

`po0.conf` 是操作员提供的 shell 配置，应只使用自己信任的内容。两个本地配置文件都被 Git 忽略；实际镜像设置会随本次 initrd 保存。

## 当前边界

- 发行版入口保留，不等于全部镜像、架构、源系统和安装方法已验证。
- 上游弃用的 Ubuntu/RHEL `--installer` 路径需要第二次启动时携带安装配置，当前明确停止在改引导之前；这些系统默认的云镜像安装入口保留。
- Windows 源系统的 Cygwin/bootstrap 和部分可选功能仍可能需要额外可达资源，尚未验证。Windows 安装目标保留。
- ELTS、Windows 驱动、frpc、第三方发行版等资源不保证在腾讯镜像中存在，可用自定义映射覆盖。
- `trans.sh update` 和 `--commit` 单文件更新方式已移除，升级时应替换完整 bundle，避免版本混用。
- 磁盘写入、实际启动和重装完成后的联网验证仍需在可恢复的测试机器上进行。主机准备脚本不会自行触发第一次重启；进入安装环境后，安装成功仍会按上游逻辑自动重启，除非使用相应的 `--hold` 暂停模式。

## 开发验证

```sh
python3 -m unittest discover -s tests -p 'test*.py' -v
sh tests/test-network.sh
bash tests/test-trans.sh
bash -n reinstall.sh
busybox ash -n trans.sh
busybox ash -n initrd-network.sh
```

测试使用临时文件和模拟网卡命令，不运行重装入口，不修改真实网络或引导。CI 也只执行这些测试和打包检查。

## 上游

基线为 `bin456789/reinstall` 的 `01e1e259968c3b9c5ee5d6aea7253392b5eafe92`。原始文档保存在 `README.upstream.md`、`README.upstream.en.md`；许可证见 [LICENSE](LICENSE)。
