# reinstall-Po0

面向 Po0 内网环境的系统重装脚本，基于 [bin456789/reinstall](https://github.com/bin456789/reinstall)，保留上游多发行版选择及 GPL-3.0 许可证。

**已在一个 Po0 x86_64/BIOS 实例完成 Debian 12、Ubuntu 24.04.5、AlmaLinux 9.8、Ubuntu 22.04.5 的真实清盘重装、首次启动、公钥 SSH、内网软件源和 chrony 同步验证。** 脚本从 Linux 系统运行，保留多发行版目标选择。其他目标和硬件路径尚未完成整机验证，详见 [本轮实机记录](docs/live-test-2026-10-28.md)。

## Po0 上的变化

- 不再访问公网服务判断地区或联网状态，不再因公网探测失败删除 IP、路由或禁用 DHCP。
- 安装环境按 MAC 找到网卡并请求 DHCP，保留获得的内网地址、网关、DNS；公网映射地址不写入网卡。
- DHCP 超时时可在安装环境临时使用原网络配置，目标系统仍配置为 DHCP。原系统实际 DNS 随安装文件保存；缺少有效 DHCP DNS 时，将保存的解析器传递到目标网络配置，不使用公共 DNS 回退。
- 默认镜像为 `http://mirrors.tencentyun.com`；下载和目标系统的软件源接入统一 URL 映射，Debian security 单独处理。
- 软件包源继续使用内网；QCOW2 云镜像优先内网，缺失或不可访问时依次尝试南大、中科大、清华的 rsync 873，Ubuntu 另有官方 rsync 候选。目录/索引发现也使用云镜像专用回退，软件包下载不会切换到校园源。
- Debian/Kali 安装器及已接入的 Debian/Ubuntu/RPM 云镜像、Alpine 路径安装 chrony，使用 `time1` 至 `time5.tencentyun.com`，并启用开机启动。禁用 chrony 的默认公网池和 DHCP/包含文件引入的时间源；保留发行版自带的状态、日志和权限配置。
- 安装过程只提供 SSH/screen 日志，删除 Web 日志服务、页面、`--web-port` / `--http-port` 及其专用依赖。
- 使用完整本地 bundle。辅助脚本、Debian preseed 和配置随 initrd 携带，经过 Alpine `switch_root` 后仍保留，不从上游 GitHub/CNB 拉取另一版本脚本。
- Linux 内核、initrd、辅助文件及 Linux EFI GRUB 下载/打包成功后才替换现有重装引导文件。保留磁盘识别、引导模式、架构和格式检查。

这不是原 Po0 面板镜像的复制工具，不会把厂商旧 Python、全部调优参数或某台实例的 IP/MAC 固定写入新系统。

## DNS、时间与厂商调优

DNS 优先使用 DHCP 提供的地址。本机实测仍为腾讯 VPC DNS `183.60.83.19`、`183.60.82.98`；保存原 DNS 只用于安装环境未获得有效 DNS 时回退，不强行把每台机器写成固定地址。参见 [腾讯内网服务文档](https://cloud.tencent.com/document/product/213/5225)。

chrony 的五个内网时间域名与 [腾讯官方配置](https://cloud.tencent.com/document/product/213/30393) 一致。本轮四个目标系统均在实际重装后的首次启动中验证服务启用、运行、内网源响应及 `NTPSynchronized=yes`。

原镜像强制 `eth0` 只是命名约定，当前通过 MAC 识别并修正网络配置；安装后叫 `ens5` 也正常。串口控制台用于查看启动/故障日志。CPU C-state、调频以及 IRQ/RPS/XPS 已在这台 2 vCPU/双队列实例上评估，没有观察到值得引入厂商脚本的收益，因此不照搬其整套配置。Tencent 磁盘 `max_sectors_kb=512` 规则继续保留，这表示单次 I/O 请求上限约 512 KiB，并非带宽限速。

## 安装资源状态

截至 2026-10-28，在一个 Po0 实例上的验证情况如下。资源可访问与完整安装通过分别记录。

| 路径 | 当前观察 |
|---|---|
| Debian 12 常规安装 | 已完成真实重装、首次启动、公钥 SSH 和内网基础源/updates/security 更新验证 |
| Debian 13 | Release 文件可访问；未进行完整安装 |
| Alpine 3.24 | 作为三轮云镜像重装的真实中间环境通过；Alpine 作为最终目标尚未验证 |
| AlmaLinux 9 | 内网 HTTP GenericCloud 完整安装通过；实际为 9.8，不是固定 9.5 |
| Ubuntu 22.04 / 24.04 | 内网镜像缺失时自动选 rsync，两者均完成镜像校验、清盘安装、启动、SSH、内网 APT 与 chrony 验证 |
| Debian `--ci` | 内网 `debian-cdimage` 路径 404 后可自动选 rsync；已验证 Debian 12 对应文件可列出 |
| Rocky 9 | 内网默认 GenericCloud 文件缺失，已验证可自动选到南大 rsync 对应文件 |
| 其他上游发行版 | 保留入口，需要逐一验证镜像、软件源及安装流程 |

未匹配的用户 URL 会原样使用。自动回退只适用于云镜像，使用 rsync 873，不退回已知不可达的公网 HTTP/HTTPS。

## 云镜像与自动选源

[MirrorZ／教育网联合镜像站](https://mirrors.cernet.edu.cn/) 的自动分流是 HTTP 302，不能作为 rsync 地址或 rsync 重定向器。Po0 安装过程不依赖其 80/443 接口；候选 rsync 端点随 bundle 保存，按实际目标文件可用性有界切换。这是可用源故障切换，不保证测出实时最快的站点，也不对镜像站做额外测速。

**rsync 镜像只在安装阶段下载一次。** 原系统准备阶段只查询文件大小、按文件名记录预期格式，并尝试获取最多 1 MiB 的 SHA256 校验清单；initrd 只携带这些元数据，不需要原系统存放整份镜像。实际 QCOW2 格式、结构及独立性在安装阶段验证，拒绝依赖 backing/data 文件的镜像。内网 HTTP 与 rsync 共用完整镜像校验入口。

HTTP 与 rsync 的普通 QCOW2 在分区前检查元数据、远端大小及暂存分区空间，随后下载、校验再安装。有精确匹配文件名的 SHA256 清单时严格比较；找不到清单时会明确提示，检查传输结果、可用的大小信息和 QCOW2 结构。校验清单与镜像来自同一镜像站，不等同于验证发行方签名。普通镜像的完整验证发生在重建分区之后，不能保证下载失败时保留旧系统。

支持普通 QCOW2 及 gzip/xz/zstd 包装的 QCOW2。压缩文件在安装环境先下载到 RAM，完整解压计数后再分区，随后直接从 RAM 展开到安装分区，不再次下载。此路径要求可用内存容纳压缩包并额外保留 512 MiB，且 RAM 文件系统空间足够；不满足时在分区前停止，可选择未包装的 QCOW2 镜像。xz/zstd 解码内存限制为 256 MiB。压缩 HTTP 镜像需要 Content-Length，缺失时在分区前停止；普通 HTTP 未给出大小时保留 2 GiB 暂存分区默认值。原始 DD/ISO 的 rsync 流式安装不在此次接入范围内，会明确拒绝；原有 HTTP 路径保留。

2026-10-28 单次下载实测：Ubuntu 24.04 内网 404 后选到南大 rsync，准备阶段只取元数据，耗时约 1 秒、镜像下载次数为 0；安装下载函数完整下载 621,284,352 字节一次，下载加 SHA256/QCOW2 结构校验约 16 秒。校验值与镜像站 SHA256SUMS 匹配。另在真实 BusyBox ash 中通过回环 rsync 验证压缩 QCOW2 只传输一次、复用 RAM 缓存，以及错误格式在分区前被拒绝。此前已验证 AlmaLinux 9 选择内网，Ubuntu 22.04、Rocky 9、Debian 12 云镜像可解析到 rsync 文件。随后已完成 Ubuntu 24.04、AlmaLinux 9.8、Ubuntu 22.04 的完整清盘重装与首次启动验证，见本轮实机记录。

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

需要覆盖默认云镜像位置时，可复制 `po0-mirrors.conf.example` 为 `po0-mirrors.conf`，每行两个 HTTP(S) URL 前缀，以空格或制表符分隔，第一条匹配生效。例如使用你控制、且 Po0 能访问的服务：

```text
https://mirror.nju.edu.cn/ubuntu-cloud-images/ http://YOUR-MIRROR:8080/ubuntu-cloud-images/
```

这里的主机和端口只是占位示例，不表示该端口已经放通。映射文件使用原始 URL 前缀；映射不会执行 shell 表达式，也不自动寻找公网代理。

也可以为某次安装直接指定可达镜像：

```sh
sudo bash reinstall.sh ubuntu 24.04 --img 'http://YOUR-MIRROR:PORT/ubuntu-24.04-server-cloudimg-amd64.img' --ssh-key /root/.ssh/authorized_keys
```

QCOW2 云镜像也可显式指定 `--img rsync://HOST/MODULE/path/image.qcow2`；软件包源仍使用内网。

`po0.conf` 是操作员提供的 shell 配置，应只使用自己信任的内容。两个本地配置文件都被 Git 忽略；实际镜像设置会随本次 initrd 保存。

## 当前边界

- 发行版入口保留，不等于全部镜像、架构和安装方法已验证。Gentoo 已改为内网签名快照和二进制源，保留签名检查并关闭外部钥匙刷新；目前仅有资源探测与隔离测试，没有整机安装结果。
- 上游弃用的 Ubuntu/RHEL `--installer` 路径需要第二次启动时携带安装配置，当前明确停止在改引导之前；这些系统默认的云镜像安装入口保留；不可达的旧安装器实现及专用文件已移除。
- 脚本只从 Linux 源系统运行；已删除 Windows/Cygwin 启动入口和相关依赖。Windows 安装目标仍保留，其驱动及可选资源尚未完成 Po0 安装验证。
- ELTS、Windows 驱动、frpc、第三方发行版等资源不保证在腾讯镜像中存在，可用自定义映射覆盖。
- `trans.sh update` 和 `--commit` 单文件更新方式已移除，升级时应替换完整 bundle，避免版本混用。
- 磁盘写入、实际启动和重装完成后的联网验证仍需在可恢复的测试机器上进行。主机准备脚本不会自行触发第一次重启；进入安装环境后，安装成功仍会按上游逻辑自动重启，除非使用相应的 `--hold` 暂停模式。

## 开发验证

```sh
python3 -m unittest discover -s tests -p 'test*.py' -v
sh tests/test-network.sh
bash tests/test-trans.sh
sh tests/test-chrony.sh
bash tests/test-trans-chrony.sh
sh tests/test-cloud-transport.sh
bash tests/test-trans-cloud.sh
bash -n reinstall.sh
busybox ash -n trans.sh
busybox ash -n initrd-network.sh
busybox ash -n po0-chrony.sh
busybox ash -n po0-cloud.sh
```

测试使用临时文件和模拟网卡命令，不运行重装入口，不修改真实网络或引导。CI 也只执行这些测试和打包检查。

## 上游

起始基线为 `bin456789/reinstall` 的 `01e1e259968c3b9c5ee5d6aea7253392b5eafe92`；2026-10-28 已合并上游至 `54fae2067557b3c0ca49e7c9ce03bca63c793f8c`。此次同步接入安装提示、网络故障日志与 DNS 配置接口，保留 Po0 不做公网联网探测、不因探测结果切换 DHCP 的策略。原始文档保存在 `README.upstream.md`、`README.upstream.en.md`；许可证见 [LICENSE](LICENSE)。
