<!-- markdownlint-disable MD028 MD033 MD045 -->

# reinstall-Po0

[![Po0 checks](https://github.com/mihomoQ/reinstall-Po0/actions/workflows/run_reinstall.yml/badge.svg)](https://github.com/mihomoQ/reinstall-Po0/actions/workflows/run_reinstall.yml)
[![License](https://img.shields.io/github/license/mihomoQ/reinstall-Po0)](LICENSE)

Po0 专用一键 DD / 系统重装脚本 [English](README.en.md)

基于 [bin456789/reinstall](https://github.com/bin456789/reinstall)，沿用上游文档结构和多发行版功能，针对 Po0 的内网源、私网 DHCP 和公网 80/443 限制进行适配。只从 **Linux 源系统**运行，完整目录或 bundle 必须一起使用。

## 介绍

- 保留重装 Linux、DD RAW、Alpine Live OS、netboot.xyz 和 Windows 目标入口；各入口的 Po0 验证状态见下表。
- 仅支持从 Linux 发起重装，已移除 Windows/Cygwin 源系统启动方式。
- 按 MAC 识别网卡并使用私网 DHCP；公网映射地址不写入网卡，不用公网连通性探测决定是否删除地址或关闭 DHCP。
- 软件包源使用内网；QCOW2 云镜像优先内网，没有时按文件可用性尝试校园 rsync（873），Ubuntu 另有官方 rsync 候选。
- HTTP 和 rsync 云镜像共用大小、可用 SHA256、QCOW2 结构和独立性校验，完整镜像只在安装阶段下载一次。
- 安装日志使用 SSH/screen；不提供 Web 日志服务。配置、辅助脚本和 preseed 随 initrd 携带，不在安装中临时下载上游脚本。
- 已接入的目标使用 chrony 和 `time1` 至 `time5.tencentyun.com` 内网时间源。
- 保留分区表 ID 磁盘识别、BIOS/EFI 和架构处理。Po0 整机实测仅覆盖 x86_64/BIOS，不能据此承诺其他硬件均通过。
- 2026-10-28 已完成五轮真实重装，覆盖 Debian 12、Ubuntu 22.04、Ubuntu 24.04、AlmaLinux 9 作为源系统和目标系统；[完整记录](docs/live-test-2026-10-28.md)。

支持上游作者（以下为原项目的赞助链接）：
[![Donate](https://img.shields.io/badge/Donate-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=#EA4AAA)](https://github.com/sponsors/bin456789)

[![Sponsors](https://raw.githubusercontent.com/bin456789/sponsors/refs/heads/master/sponsors.svg)](https://github.com/sponsors/bin456789)

### 反馈

[![GitHub Issues](https://img.shields.io/badge/GitHub-%23121011.svg?style=for-the-badge&logo=github&logoColor=white)](https://github.com/mihomoQ/reinstall-Po0/issues)
上游交流群：[![Telegram Group](https://img.shields.io/badge/Telegram-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/reinstall_os)

## 快速开始

- [下载](#下载当前系统是--linux)
- [功能 1. 一键重装到 Linux](#功能-1-安装--linux)
- [功能 2. 一键 DD Raw 镜像到硬盘](#功能-2-dd-raw-镜像到硬盘)
- [功能 3. 一键引导到 Alpine Live OS 内存系统](#功能-3-重启到--alpine-live-os内存系统)
- [功能 4. 一键引导到 netboot.xyz](#功能-4-重启到--netbootxyz)
- [功能 5. 一键重装到 Windows](#功能-5-安装--windows-iso)
- [取消重装](#取消重装)

## 系统要求

源系统必须是 Linux。本轮实际验证的源系统为 Debian 12、Ubuntu 22.04、Ubuntu 24.04、AlmaLinux 9.8。

**已完整验证的目标和命令：**

| 命令 | 本轮实际安装版本 | 验证结果 |
|---|---|---|
| `bash reinstall.sh debian 12` | Debian 12 | 清盘安装、启动、公钥 SSH、内网 APT、chrony 通过 |
| `bash reinstall.sh ubuntu 22.04` | Ubuntu 22.04.5 LTS | 同上 |
| `bash reinstall.sh ubuntu 24.04` | Ubuntu 24.04.5 LTS | 同上 |
| `bash reinstall.sh almalinux 9` | AlmaLinux 9.8 | 清盘安装、启动、公钥 SSH、内网 DNF、chrony 通过 |

命令接收发行系列，不接受 `ubuntu 24.04.5`、`almalinux 9.5` 或 `almalinux 9.8` 这样的点版本。默认云镜像随镜像源更新，不能保证固定安装面板的 AlmaLinux 9.5。

**以下完整版本表表示脚本保留的入口，不等同于所有版本在 Po0 都可直接装成功。** 未标实测的版本还依赖镜像、软件源及辅助资源可达。建议显式填写版本；省略版本会选脚本版本表最后一项，例如 Debian 13、Ubuntu 26.10、AlmaLinux 10，而不是上面的实测版本。

目标系统的资源要求沿用上游作为参考，**不是 Po0 全版本实测最低配置**。本轮测试机器为 2 vCPU、2 GiB RAM、20 GiB 系统盘。

| 系统 | 脚本接受的版本/参数 | 上游内存参考 | 上游硬盘参考 | Po0 验证状态 |
|---|---|---|---|---|
| Alpine | 3.21、3.22、3.23、3.24 | 256 MB | 1 GB | 3.24 已作为云镜像安装的中间环境；最终目标未测 |
| Debian | 9、10、11、12、13 | 256 MB | 1～1.5 GB ^ | **12 已完整验证**；9～11 的 ELTS 路径有额外资源限制 |
| Kali | last-snapshot、rolling | 256 MB | 1～1.5 GB ^ | 未完整验证 |
| Ubuntu | 18.04、20.04、22.04、24.04、26.04、26.10 | 512 MB * | 2 GB | **22.04、24.04 已完整验证** |
| Anolis | 7、8、23 | 512 MB * | 5 GB | 未完整验证 |
| AlmaLinux | 8、9、10 | 512 MB * | 5 GB | **9 已完整验证，镜像实际为 9.8** |
| Rocky | 8、9、10 | 512 MB * | 5 GB | 9 已验证选源，未完整重装 |
| Oracle Linux | 8、9、10 | 512 MB * | 5 GB | 未完整验证 |
| RHEL / 其他兼容云镜像 | `redhat --img URL`，不单独填写版本 | 512 MB * | 5 GB | 需自行提供可达 QCOW2，未完整验证 |
| OpenCloudOS | 8、9、23（Stream） | 512 MB * | 5 GB | 未完整验证 |
| CentOS Stream | 9、10 | 512 MB * | 5 GB | 未完整验证；另保留隐藏的 CentOS 7 历史入口 |
| Fedora | 43、44 | 512 MB * | 5 GB | 未完整验证 |
| openEuler | 20.03、22.03、24.03、26.09 | 512 MB * | 5 GB | 未完整验证；压缩镜像另需 RAM 缓存 |
| openSUSE | 16.0、tumbleweed | 512 MB * | 5 GB | 未完整验证 |
| NixOS | 26.05 | 512 MB | 5 GB | 未完整验证 |
| Arch Linux / Arch Linux ARM | 滚动，不填版本号 | 512 MB | 5 GB | 未完整验证 |
| Gentoo | 滚动，不填版本号 | 512 MB | 5 GB | 内网快照/签名/二进制索引可达，未完整安装 |
| 安同 OS | 滚动，不填版本号 | 512 MB | 5 GB | 未完整验证 |
| fnOS / FygoOS | 1 | 512 MB | 10 GB | 未完整验证 |
| Windows（DD） | 由 `--img` 镜像决定 | 512 MB | 取决于镜像 | 未完整验证 |
| Windows（ISO） | Vista～11、Server 2008～2025 等，见功能 5 | 512 MB～1 GB | 25 GB | 未完整验证；本轮 20 GiB 测试盘也不满足此参考要求 |

\* 表示使用云镜像安装，非传统网络安装

^ 表示需要 256 MB 内存 + 1.5 GB 硬盘，或 512 MB 内存 + 1 GB 硬盘

Po0 云镜像安装还会检查暂存分区、引导空间和目标系统空间。gzip/xz/zstd 包装的 QCOW2 要求可用内存容纳压缩包并额外保留 512 MiB，RAM 文件系统空间也必须足够；xz/zstd 解码内存限制为 256 MiB。压缩 HTTP 镜像还需要 Content-Length。上述条件不能由“512 MB”这一上游参考值替代。

内网没有某个软件仓库时，不会自动切到校园公网软件源。rsync 回退仅用于云镜像；ELTS 公钥、Kali 辅助文件、Oracle 索引、netboot.xyz、Windows 驱动和可选工具等仍需逐项确认可达，不能仅凭版本参数存在就视为可用。

> [!WARNING]
>
> 上游还提供独服和 PC 的通用支持；本分支只验证了 Po0 环境
>
> 但如果能使用 IPMI 或 U 盘，则不建议使用本脚本

> [!WARNING]
>
> ❌ 本脚本不支持 OpenVZ、LXC 虚拟机
>
> 请改用 <https://github.com/LloydAsp/OsMutation>

## 下载（当前系统是 <img width="20" height="20" src="https://www.kernel.org/theme/images/logos/favicon.png" /> Linux）

Po0 公网 80/443 受限，**不能使用上游的单文件下载方式**。在能访问 GitHub 的电脑上克隆完整仓库，再通过 SCP/SFTP 上传：

```bash
# 在能访问 GitHub 的电脑执行
git clone https://github.com/mihomoQ/reinstall-Po0.git
scp -r reinstall-Po0 root@YOUR_SERVER:/root/
```

也可构建带文件校验的 bundle（电脑需要 Python），再上传解压：

```bash
cd reinstall-Po0
python3 tools/build-bundle.py
scp dist/reinstall-Po0.tar.gz root@YOUR_SERVER:/root/
```

```bash
# 在 Po0 的 Linux 系统执行
cd /root
tar xzf reinstall-Po0.tar.gz
cd reinstall-Po0
sha256sum -c SHA256SUMS
```

这里的 `YOUR_SERVER` 需要替换为自己的机器地址，SSH 端口和密钥按实际情况配置。不得只上传 `reinstall.sh`；`po0-assets.list` 列出的配套文件都必须保留。

## 使用

从完整目录中以 root 运行 `bash reinstall.sh ...`。不支持从 Windows/Cygwin 发起安装；文档后面的 Windows 章节指 **Windows 安装目标**。

### 功能 1: 安装 <img width="16" height="16" src="https://www.kernel.org/theme/images/logos/favicon.png" /> Linux

> [!CAUTION]
>
> 此功能会清除当前系统**整个硬盘**的全部数据（包含其它分区）！
>
> 如果不小心运行了脚本，可以在重启前运行 `bash reinstall.sh reset` 取消重装

- 脚本会提示输入用户名和密码，不输入则使用 `root` 和随机密码
- 不输入版本号则选择脚本版本表最后一项；在 Po0 建议显式指定已经实测的版本
- 尽量扩展目标系统分区；具体分区布局取决于安装方法和镜像，云镜像暂存分区会在安装后回收
- 根据发行版和虚拟化环境选择相应内核
- 安装 Red Hat 的入口保留但尚未完成 Po0 整机验证；需填写 <https://access.redhat.com/downloads/content/rhel> 得到的 `qcow2` 镜像链接，也可以安装其它类 RHEL 系统的 `qcow2`，例如 `Alibaba Cloud Linux` 和 `TencentOS Server`
- 建议直接使用本地公钥参数，例如 `bash reinstall.sh debian 12 --ssh-key /root/.ssh/authorized_keys`。重装后修改 SSH 配置时，也要检查 `/etc/ssh/sshd_config.d/`
- 不执行整套系统升级；安装必需组件时可能更新内核或依赖，重装后可自行检查其余更新
- 安装飞牛 fnOS/FygoOS 时设置的用户名、密码、密钥仅用于安装期间登录 SSH 查看日志，不会应用到新系统。系统安装后需到后台面板 <http://IP:5666> 创建用户和开启 SSH

下面是参数速查表，`|` 表示从中选择一个版本，不能整行原样执行：

```text
bash reinstall.sh anolis      7|8|23
                  rocky       8|9|10
                  oracle      8|9|10
                  almalinux   8|9|10
                  opencloudos 8|9|23
                  centos      9|10
                  fnos        1
                  fygoos      1
                  nixos       26.05
                  fedora      43|44
                  debian      9|10|11|12|13
                  opensuse    16.0|tumbleweed
                  alpine      3.21|3.22|3.23|3.24
                  kali        last-snapshot|rolling
                  openeuler   20.03|22.03|24.03|26.09
                  ubuntu      18.04|20.04|22.04|24.04|26.04|26.10 [--minimal]
                  arch
                  gentoo
                  aosc
                  redhat      --img="http://access.cdn.redhat.com/xxx.qcow2"
```

#### 可选参数

- `--username USERNAME` 设置用户名
- `--password PASSWORD` 设置密码
- `--ssh-key KEY` 设置 SSH 登录公钥，[格式如下](#--ssh-key)。当使用公钥时，密码为空
- `--ssh-port PORT` 修改 SSH 端口
- `--frpc-config PATH` 添加 frpc 内网穿透，参数填配置文件的本地路径或 HTTP 链接
- `--no-cloud-kernel` 不使用云内核，避免部分机器黑屏/花屏，适用于 Debian、Ubuntu、Alpine、openSUSE
- `--hold 1` 仅重启到安装环境，不运行安装，用于 SSH 登录验证网络连通性
- `--hold 2` 安装结束后不重启，用于 SSH 登录修改系统内容，Debian/Kali 会挂载在 `/target`，其它系统会挂载在 `/os`

> [!TIP]
>
> 安装日志通过 SSH/screen 查看，不提供 HTTP/Web 日志。商家控制台仍可用于查看启动故障。
>
> 安装环境网络和 SSH 仍正常时，可登录处理错误；若失联则需要商家面板恢复。
>
> 目标系统非 Debian/Kali 时，可以运行 `/trans.sh alpine` 自动救砖成 Alpine 系统。

#### 其他安装方式

Debian 云镜像入口仍保留，但尚未完成 Po0 整机验证：

```bash
bash reinstall.sh debian 12 --ci
```

上游旧的 Ubuntu/RHEL 系 `--installer` 方式在本分支明确拒绝，相关不可达实现和专用资源已删除；这些发行版的默认云镜像入口仍保留。

#### Po0 镜像与日志

- 默认内网源：`http://mirrors.tencentyun.com`。DNS 优先使用 DHCP 获得的配置；缺少可用 DNS 时使用准备阶段保存的解析器，目标 IP 仍保持 DHCP。
- 云镜像缺失时按可用性尝试南大、中科大、清华 rsync，Ubuntu 另有官方 rsync 候选。[MirrorZ / 教育网联合镜像站](https://mirrors.cernet.edu.cn/) 的 HTTP 302 不能作为 rsync 重定向器，本脚本不依赖其公网接口，也不承诺实时最快源。
- 镜像有匹配 SHA256 清单时严格校验；没有时明确提示，并检查传输、可用大小和 QCOW2 结构。镜像站提供的清单不等于发行方签名认证。
- 普通云镜像在重建分区后下载和完整校验；失败时可能需要面板恢复，不能保证保留旧系统。
- Debian/Kali 安装器可运行 `tail -f /var/log/syslog` 或 `screen -x root/`；Alpine 中间环境可运行 `tail -f /reinstall.log`。
- 常规路径会安装 chrony 并使用腾讯五个内网时间源；完整验证范围见上表。未照搬厂商整套 CPU/IRQ/RPS/XPS 调优脚本；保留腾讯 virtio 磁盘 `max_sectors_kb=512` 规则。

### 功能 2: DD RAW 镜像到硬盘

> [!IMPORTANT]
> 此入口在 Po0 未完成整机验证。镜像地址必须能从 Po0 访问；示例端口不是自动放通的服务。原始 DD 不支持 rsync，rsync 回退仅用于 QCOW2 云镜像安装。

> [!CAUTION]
>
> 此功能会清除当前系统**整个硬盘**的全部数据（包含其它分区）！
>
> 如果不小心运行了脚本，可以在重启前运行 `bash reinstall.sh reset` 取消重装

- 支持 `raw` 和固定大小的 `vhd` 镜像。未压缩或者压缩成 `.gz` `.xz` `.zst` `.tar` `.tar.gz` `.tar.xz` `.tar.zst`
- DD Windows 镜像时，会自动扩展系统盘，静态 IP 的机器会配置好 IP，可能首次开机几分钟后才生效
- DD Linux 镜像默认不修改镜像内容；显式指定 `--cloud-data` 时会注入相应配置
- 脚本会提示输入用户名和密码，用于安装时 SSH 登录观察日志，不输入则使用 `root` 和随机密码

```bash
bash reinstall.sh dd --img "http://YOUR-MIRROR:8080/xxx.xz"
```

#### 可选参数

- `--username USERNAME` 设置用户名（安装期间观察日志用）
- `--password PASSWORD` 设置密码（安装期间观察日志用）
- `--ssh-key KEY` 设置 SSH 登录公钥（安装期间观察日志用），[格式如下](#--ssh-key)。当使用公钥时，密码为空
- `--ssh-port PORT` 修改 SSH 端口（安装期间观察日志用）
- `--rdp-port PORT` 修改 RDP 端口（仅限 DD Windows）
- `--allow-ping` 设置 Windows 防火墙允许被 Ping（仅限 DD Windows）
- `--frpc-config PATH` 添加 frpc 内网穿透（仅限 DD Windows），参数填配置文件的本地路径或 HTTP 链接
- `--cloud-data PATH_OR_URL` 为 DD Linux 镜像注入 cloud-init NoCloud 配置（仅限 DD Linux）
- `--hold 1` 仅重启到安装环境，不运行安装，用于 SSH 登录验证网络连通性
- `--hold 2` DD 结束后不重启，用于 SSH 登录修改系统内容，Windows 系统会挂载在 `/os`，Linux 系统**不会**自动挂载

> [!TIP]
>
> `--cloud-data` 参数为本地目录或 HTTP 基础 URL，目录须包含 `user-data` 文件，`meta-data`、`network-config` 可选：
>
> ```bash
> seed/
> ├── user-data      # 必须
> ├── meta-data      # 可选
> └── network-config # 可选
> ```
>
> ```bash
> # 使用本地目录
> bash reinstall.sh dd --img "http://YOUR-MIRROR:8080/xxx.xz" --cloud-data /path/to/seed/
> # 使用 HTTP 目录
> bash reinstall.sh dd --img "http://YOUR-MIRROR:8080/xxx.xz" --cloud-data "http://YOUR-MIRROR:8080/seed/"
> ```

> [!TIP]
>
> 安装日志通过 SSH/screen 查看，不提供 HTTP/Web 日志。商家控制台仍可用于查看启动故障。
>
> 安装环境网络和 SSH 仍正常时，可登录处理错误；若失联则需要商家面板恢复
>
> 也可以运行 `/trans.sh alpine` 自动救砖成 Alpine 系统。

### 功能 3: 重启到 <img width="16" height="16" src="https://www.alpinelinux.org/alpine-logo.ico" /> Alpine Live OS（内存系统）

- 可用 ssh 连接，进行备份/恢复硬盘、手动 DD、修改分区、手动安装 Alpine 等操作
- 脚本会提示输入用户名和密码，不输入则使用 `root` 和随机密码

> [!TIP]
>
> 虽然运行的脚本叫 `reinstall`，但是此功能**不会**删除任何数据和进行自动重装，而是要用户手动操作
>
> 如果用户手动操作没有破坏原系统，再次重启将回到原系统

```bash
bash reinstall.sh alpine --hold 1
```

#### 可选参数

- `--username USERNAME` 设置用户名
- `--password PASSWORD` 设置密码
- `--ssh-key KEY` 设置 SSH 登录公钥，[格式如下](#--ssh-key)。当使用公钥时，密码为空
- `--ssh-port PORT` 修改 SSH 端口
- `--frpc-config PATH` 添加 frpc 内网穿透，参数填配置文件的本地路径或 HTTP 链接

### 功能 4: 重启到 <img width="16" height="16" src="https://netboot.xyz/img/favicon.ico" /> netboot.xyz

> [!IMPORTANT]
> 入口保留，Po0 未完成验证。netboot.xyz 引导文件和菜单通常需要公网 HTTP/HTTPS，端口限制下不能保证可用。

- 可使用商家后台 VNC 手动安装 [更多系统](https://github.com/netbootxyz/netboot.xyz?tab=readme-ov-file#what-operating-systems-are-currently-available-on-netbootxyz)

> [!TIP]
>
> 虽然运行的脚本叫 `reinstall`，但是此功能**不会**删除任何数据和进行自动重装，而是要用户手动操作
>
> 如果用户手动操作没有破坏原系统，再次重启将回到原系统

```bash
bash reinstall.sh netboot.xyz
```

![netboot.xyz](https://netboot.xyz/images/netboot.xyz.gif)

### 功能 5: 安装 <img width="16" height="16" src="https://blogs.windows.com/wp-content/uploads/prod/2022/09/cropped-Windows11IconTransparent512-32x32.png" /> Windows ISO

> [!IMPORTANT]
> 本节保留上游的 Windows **目标安装**用法，不代表 Po0 已验证。自动查找 ISO、驱动下载可能依赖被限制的公网 80/443；使用前必须解决资源可达性和磁盘容量要求。没有 Windows 源系统启动入口。

![Windows 安装界面](https://github.com/bin456789/reinstall/assets/7548515/07c1aea2-1ce3-4967-904f-aaf9d6eec3f7)

> [!CAUTION]
>
> 此功能会清除当前系统**整个硬盘**的全部数据（包含其它分区）！
>
> 如果不小心运行了脚本，可以在重启前运行 `bash reinstall.sh reset` 取消重装

- 脚本会提示输入用户名和密码，不输入则使用 `administrator` 和随机密码
- 如果远程登录失败，请尝试在用户名前添加 `.\`，例如 `.\administrator`
- 少数语言的系统管理员账号不是 `administrator` [详情](https://learn.microsoft.com/archive/technet-wiki/13813.localized-names-for-administrator-account-in-windows#list-of-languages-that-localize-the-administrator-account-name)
- 静态机器会自动配置好 IP，可能首次开机几分钟后才生效
- 支持任意语言的 ISO
- 自动绕过 Windows 11 硬件限制

#### 支持的系统

- Windows (Vista ~ 11)
- Windows Server (2008 ~ 2025)
  - Windows Server Essentials
  - Windows Server (Semi) Annual Channel
  - Hyper-V Server
  - Azure Local (Azure Stack HCI)

#### 方法 1: 让脚本自动查找 ISO

仅在相关站点可访问时适用；Po0 默认网络条件下不保证成功。

- 脚本会从 <https://ntriver.org/download-windows-office> 查找 ISO，该网站专门收集官方 ISO 镜像
- 默认查找 64 位系统镜像，除非指定了 `--bit 32`

```bash
bash reinstall.sh windows \
     --image-name "Windows 11 Enterprise LTSC 2024" \
     --lang zh-cn
```

<details>
<summary>--image-name 列表</summary>

以下版本支持自动查找，其它版本请用方法 2 手动指定 ISO 链接安装

```text
Windows Vista Starter
Windows Vista HomeBasic
Windows Vista HomePremium
Windows Vista Business
Windows Vista Ultimate
Windows Vista Enterprise

Windows 7 Starter
Windows 7 HomeBasic
Windows 7 HomePremium
Windows 7 Professional
Windows 7 Ultimate
Windows 7 Enterprise

Windows 8
Windows 8 Pro
Windows 8 Enterprise

Windows 8.1
Windows 8.1 Pro
Windows 8.1 Enterprise

Windows 10 Home
Windows 10 Home Single Language
Windows 10 Pro
Windows 10 Pro Education
Windows 10 Pro for Workstations
Windows 10 Education
Windows 10 Enterprise
Windows 10 Enterprise 2015 LTSB
Windows 10 Enterprise 2016 LTSB
Windows 10 Enterprise LTSC 2019
Windows 10 Enterprise LTSC 2021
Windows 10 IoT Enterprise
Windows 10 IoT Enterprise 2015 LTSB
Windows 10 IoT Enterprise 2016 LTSB
Windows 10 IoT Enterprise LTSC 2019
Windows 10 IoT Enterprise LTSC 2021

Windows 11 Home
Windows 11 Home Single Language
Windows 11 Pro
Windows 11 Pro Education
Windows 11 Pro for Workstations
Windows 11 Education
Windows 11 Enterprise
Windows 11 Enterprise LTSC 2024
Windows 11 IoT Enterprise
Windows 11 IoT Enterprise LTSC 2024
Windows 11 IoT Enterprise Subscription
Windows 11 IoT Enterprise Subscription LTSC 2024

Windows Longhorn ServerWeb
Windows Longhorn ServerWebCore
Windows Longhorn ServerStandard
Windows Longhorn ServerStandardCore
Windows Longhorn ServerEnterprise
Windows Longhorn ServerEnterpriseCore
Windows Longhorn ServerDatacenter
Windows Longhorn ServerDatacenterCore

Windows Server 2008 R2 ServerWeb
Windows Server 2008 R2 ServerWebCore
Windows Server 2008 R2 ServerStandard
Windows Server 2008 R2 ServerStandardCore
Windows Server 2008 R2 ServerEnterprise
Windows Server 2008 R2 ServerEnterpriseCore
Windows Server 2008 R2 ServerDatacenter
Windows Server 2008 R2 ServerDatacenterCore

Windows Server 2012 ServerStandard
Windows Server 2012 ServerStandardCore
Windows Server 2012 ServerDatacenter
Windows Server 2012 ServerDatacenterCore

Windows Server 2012 R2 ServerStandard
Windows Server 2012 R2 ServerStandardCore
Windows Server 2012 R2 ServerDatacenter
Windows Server 2012 R2 ServerDatacenterCore

Windows Server 2016 ServerStandard
Windows Server 2016 ServerStandardCore
Windows Server 2016 ServerDatacenter
Windows Server 2016 ServerDatacenterCore

Windows Server 2019 ServerStandard
Windows Server 2019 ServerStandardCore
Windows Server 2019 ServerDatacenter
Windows Server 2019 ServerDatacenterCore

Windows Server 2022 ServerStandard
Windows Server 2022 ServerStandardCore
Windows Server 2022 ServerDatacenter
Windows Server 2022 ServerDatacenterCore

Windows Server 2025 ServerStandard
Windows Server 2025 ServerStandardCore
Windows Server 2025 ServerDatacenter
Windows Server 2025 ServerDatacenterCore
```

</details>

<details>
<summary>--lang 列表</summary>

支持这三种语言代码格式，不区分大小写

| CC 格式 | CC-CC 格式 | 语言 |
| - | - | - |
| ar | ar-sa | Arabic |
| bg | bg-bg | Bulgarian |
| cs | cs-cz | Czech |
| da | da-dk | Danish |
| de | de-de | German |
| el | el-gr | Greek |
| gb | en-gb | Eng_Intl |
| en | en-us | English |
| es | es-es | Spanish |
| mx | es-mx | Spanish_Latam |
| et | et-ee | Estonian |
| fi | fi-fi | Finnish |
| | fr-ca | FrenchCanadian |
| fr | fr-fr | French |
| he | he-il | Hebrew |
| hr | hr-hr | Croatian |
| hu | hu-hu | Hungarian |
| it | it-it | Italian |
| ja | ja-jp | Japanese |
| ko | ko-kr | Korean |
| lt | lt-lt | Lithuanian |
| lv | lv-lv | Latvian |
| no | nb-no | Norwegian |
| nl | nl-nl | Dutch |
| pl | pl-pl | Polish |
| pp | pt-pt | Portuguese |
| pt | pt-br | Brazilian |
| ro | ro-ro | Romanian |
| ru | ru-ru | Russian |
| sk | sk-sk | Slovak |
| sl | sl-si | Slovenian |
| sr | sr-latn / sr-latn-rs | Serbian_Latin |
| sv | sv-se | Swedish |
| th | th-th | Thai |
| tr | tr-tr | Turkish |
| uk | uk-ua | Ukrainian |
| cn | zh-cn | ChnSimp |
| tw | zh-tw | ChnTrad |
| hk | zh-hk | ChnTrad_Hong_Kong |

</details>

#### 方法 2: 自行指定 ISO 连接

- 如果不知道 `--image-name`，可以随便填，在重启后连接 SSH，根据错误提示重新输入正确的值

```bash
bash reinstall.sh windows \
     --image-name "Windows 11 Enterprise LTSC 2024 Evaluation" \
     --iso "https://go.microsoft.com/fwlink/?linkid=2289029"
```

或者磁力链接

```bash
bash reinstall.sh windows \
     --image-name "Windows 11 Enterprise LTSC 2024" \
     --iso "magnet:?xt=urn:btih:7352bd2db48c3381dffa783763dc75aa4a6f1cff"
```

<details>

<summary>以下网站可找到 ISO 链接</summary>

- 正式版
  - <https://ntriver.org/download-windows-office> (上游列出的 ISO 查找站点)
  - <https://massgrave.dev/genuine-installation-media> (上游列出的 ISO 查找站点)
  - <https://next.itellyou.cn>
  - <https://www.xitongku.com>
  - <https://www.microsoft.com/software-download/windows10> (需用非 Windows User-Agent 打开)
  - <https://www.microsoft.com/software-download/windows11>
  - <https://www.microsoft.com/software-download/windows11arm64>
- 评估版
  - <https://www.microsoft.com/evalcenter/download-windows-11-enterprise>
  - <https://www.microsoft.com/evalcenter/download-windows-11-iot-enterprise-ltsc-eval>
  - <https://www.microsoft.com/evalcenter/download-windows-server-2012-r2>
  - <https://www.microsoft.com/evalcenter/download-windows-server-2016>
  - <https://www.microsoft.com/evalcenter/download-windows-server-2019>
  - <https://www.microsoft.com/evalcenter/download-windows-server-2022>
  - <https://www.microsoft.com/evalcenter/download-windows-server-2025>
- Insider 预览版
  - <https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewiso>
  - <https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewserver>

</details>

#### 可选参数

- `--username USERNAME` 设置用户名
- `--password PASSWORD` 设置密码
- `--rdp-port PORT` 修改 RDP 端口
- `--ssh-port PORT` 修改 SSH 端口（安装期间观察日志用）
- `--allow-ping` 设置 Windows 防火墙允许被 Ping
- `--add-driver INF_OR_DIR` 添加额外驱动，填写 .inf 路径，或者 .inf 所在的文件夹
  - 需先下载驱动到当前系统
  - 可多次设置该参数以添加不同的驱动
- `--no-auto-drivers` 禁止脚本自动下载驱动，你需要用 `--add-driver` 补全驱动
- `--frpc-config PATH` 添加 frpc 内网穿透，参数填配置文件的本地路径或 HTTP 链接
- `--hold 1` 仅重启到安装环境，不运行安装，用于 SSH 登录验证网络连通性
- `--hold 2` 用于在进入 Windows 官方安装程序之前，SSH 登录修改 `boot.wim`、`install.wim` 或者其它内容，硬盘挂载在 `/os`

#### 上游自动驱动列表（Po0 可达性未验证）

以下为保留的按需下载逻辑，使用 `--no-auto-drivers` 可禁止；禁止后应自行准备并用 `--add-driver` 提供必要驱动。

- VirtIO ([社区版][virtio-virtio], [阿里云][virtio-aliyun], [腾讯云][virtio-qcloud], [GCP][virtio-gcp], [GCP (Win7/2008 SHA-1)][virtio-gcp-win6.1sha1])
- XEN ([~~社区版~~][xen-xen] (未签名), [Citrix][xen-citrix], [AWS][xen-aws])
- AWS ([ENA 网卡][aws-ena], [NVMe 存储控制器][aws-nvme], [VMClock 虚拟时钟][aws-vmclock], [PCI 串口][aws-pciserial])
- GCP ([gVNIC 网卡][gcp-gvnic], [GGA 显卡][gcp-gga])
- Azure ([MANA 网卡][azure-mana])
- Intel (VMD 存储控制器: [11代酷睿][intel-vmd-gen11], [12-15代酷睿][intel-vmd-gen12-to-gen15], [酷睿 Ultra 3][intel-vmd-ultra3], 网卡: [7][intel-nic-7], [8.x][intel-nic-8.1], [10][intel-nic-10], [11][intel-nic-11], [2008 R2][intel-nic-7], [2012][intel-nic-2012], [2012 R2][intel-nic-2012-r2], [2016][intel-nic-2016], [2019][intel-nic-2019], [2022][intel-nic-2022], [2025][intel-nic-2025])

[virtio-virtio]: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/
[virtio-aliyun]: https://www.alibabacloud.com/help/ecs/user-guide/install-the-virtio-driver-1
[virtio-qcloud]: https://cloud.tencent.com/document/product/213/17815#b84b2032-752c-43c4-a509-73530b8f82ff
[virtio-gcp]: https://packages.cloud.google.com/yuck/repos/google-compute-engine-stable/index
[virtio-gcp-win6.1sha1]: https://console.cloud.google.com/storage/browser/gce-windows-drivers-public/win6.1sha1
[xen-xen]: https://xenbits.xenproject.org/pvdrivers/win/
[xen-aws]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/xen-drivers-overview.html
[xen-citrix]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Upgrading_PV_drivers.html#win2008-citrix-upgrade
[aws-ena]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ena-driver-releases-windows.html
[aws-nvme]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nvme-driver-version-history.html
[aws-vmclock]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/other-windows-device-drivers.html
[aws-pciserial]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/migrating-latest-types.html#install-serial-port-bare-metal
[gcp-gvnic]: https://packages.cloud.google.com/yuck/repos/google-compute-engine-driver-gvnic-stable/index
[gcp-gga]: https://packages.cloud.google.com/yuck/repos/google-compute-engine-driver-gga-stable/index
[azure-mana]: https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-windows
[intel-vmd-gen11]: https://www.intel.com/content/www/us/en/download/849933/intel-rapid-storage-technology-driver-installation-software-with-intel-optane-memory-12th-to-13th-gen-platforms.html
[intel-vmd-gen12-to-gen15]: https://www.intel.com/content/www/us/en/download/849936/intel-rapid-storage-technology-driver-installation-software-with-intel-optane-memory-12th-to-15th-gen-platforms.html
[intel-vmd-ultra3]: https://www.intel.com/content/www/us/en/download/920456/intel-rapid-storage-technology-driver-installation-software-for-intel-core-ultra-series-3-platforms.html
[intel-nic-7]: https://www.intel.com/content/www/us/en/download/15590/intel-network-adapter-driver-for-windows-7-final-release.html
[intel-nic-8.1]: https://www.intel.com/content/www/us/en/download/17479/intel-network-adapter-driver-for-windows-8-1.html
[intel-nic-10]: https://www.intel.com/content/www/us/en/download/18293/intel-network-adapter-driver-for-windows-10.html
[intel-nic-11]: https://www.intel.com/content/www/us/en/download/727998/intel-network-adapter-driver-for-microsoft-windows-11.html
[intel-nic-2012]: https://www.intel.com/content/www/us/en/download/16789/intel-network-adapter-driver-for-windows-server-2012.html
[intel-nic-2012-r2]: https://www.intel.com/content/www/us/en/download/17480/intel-network-adapter-driver-for-windows-server-2012-r2.html
[intel-nic-2016]: https://www.intel.com/content/www/us/en/download/18737/intel-network-adapter-driver-for-windows-server-2016.html
[intel-nic-2019]: https://www.intel.com/content/www/us/en/download/19372/intel-network-adapter-driver-for-windows-server-2019.html
[intel-nic-2022]: https://www.intel.com/content/www/us/en/download/706171/intel-network-adapter-driver-for-windows-server-2022.html
[intel-nic-2025]: https://www.intel.com/content/www/us/en/download/838943/intel-network-adapter-driver-for-windows-server-2025.html

#### 如何填写映像名称 `--image-name`

一个 ISO 通常包含多个系统版本，例如家庭版、专业版。因此需要用 `--image-name` 指定要安装的系统版本（映像名称），不区分大小写

可以用 DISM、DISM++、Wimlib 等工具查询 ISO 包含的映像名称

#### 如何用 [DISM++](https://github.com/Chuyu-Team/Dism-Multi-language/releases) 查询 ISO 包含的映像名称

打开文件菜单 > 打开映像文件，选择要安装的 ISO，即可得到可用于 `--image-name` 的名称；能否完成安装仍取决于镜像、驱动和资源可达性。

![image-name](https://github.com/bin456789/reinstall/assets/7548515/5aae0a9b-61e2-4f66-bb98-d470a6beaac2)

> [!WARNING]
> Vista、Server 2008 和 32 位系统可能会缺少驱动

> [!WARNING]
>
> 安装 Vista、7、Server 2008、Server 2008 R2 时
>
> 1. EFI 引导的机器要开启 CSM
>
> 2. Hyper-V / Azure 需选择第 1 代虚拟机

> [!WARNING]
>
> Windows 10 LTSC 2021 中文版镜像 `zh-cn_windows_10_enterprise_ltsc_2021_x64_dvd_033b7312.iso` 的 `wsappx` 进程会长期占用 CPU
>
> 解决方法是更新系统补丁，或者手动安装 `VCLibs` 库 <https://www.google.com/search?q=ltsc+wsappx>

> [!WARNING]
>
> 在 GCP 上安装 `2022年5月` 和之后发布的 Windows ISO，在引导 Windows 安装界面 (PE) 时会不断反复重启。解决方法如下，二选一
>
> 1. 添加 `--force-boot-mode bios` 参数，脚本将以 `BIOS 引导 + MBR 分区表` 方式安装 Windows
>
>    (可选) 安装完成后用 `MBR2GPT /convert /allowFullOS` 命令转为 `EFI 引导 + GPT 分区表`
>
> 2. 自制 RAW 镜像并通过 DD 安装

#### ARM 安装 Windows 的注意事项

以下为上游提供的 ARM/其他商家参考，不是 Po0 实测结果；本轮 Po0 验证只有 x86_64/BIOS。

安装过程可能会黑屏，串行控制台可能会显示 `ConvertPages: failed to find range`，均不影响正常安装

| 兼容性 | 云服务商 | 实例类型                | 问题                                       |
| ------ | -------- | ----------------------- | ------------------------------------------ |
| ✔️     | Azure    | B2pts_v2                |                                            |
| ✔️     | AWS      | T4g                     |                                            |
| ✔️     | Scaleway | COPARM1                 |                                            |
| ✔️     | Gcore    |                         |                                            |
| ❔     | 阿里云   | g6r, c6r, g8y, c8y, r8y | 有几率重启时卡开机 Logo，强制重启即可      |
| ❔     | 甲骨文云 | A1.Flex                 | 不一定能安装成功，越新创建的实例越容易成功 |
| ❌     | 谷歌云   | t2a                     | 缺少网卡驱动                               |

### 取消重装

- 如果不小心运行了脚本，可以运行以下命令取消重装
- 需要在重启前运行

```bash
bash reinstall.sh reset
```

## 参数格式

### --ssh-key

- `--ssh-key "ssh-rsa ..."`
- `--ssh-key "ssh-ed25519 ..."`
- `--ssh-key "ecdsa-sha2-nistp256/384/521 ..."`
- `--ssh-key http://path/to/public_key`
- `--ssh-key github:your_username` 或 `--ssh-key gh:your_username`
- `--ssh-key gitlab:your_username` 或 `--ssh-key gl:your_username`
- `--ssh-key /path/to/public_key`

远程公钥 URL、`github:` 和 `gitlab:` 需要对应地址可达。在 Po0 上优先上传公钥文件后使用本地路径；不要依赖被限制的公网接口。

## 如何使用旧版本

在能够访问 GitHub 的电脑上，从 [本仓库提交历史](https://github.com/mihomoQ/reinstall-Po0/commits/main) 选择版本，检出**整套文件**后重新构建并上传：

```bash
git clone https://github.com/mihomoQ/reinstall-Po0.git
cd reinstall-Po0
git checkout COMMIT_ID
python3 tools/build-bundle.py
```

将 `COMMIT_ID` 替换为要使用的提交。不要只替换单个脚本，也不要混用不同版本的辅助文件。上游 `--commit` 和 `trans.sh update` 单文件更新方式在本分支已移除。

## 如何修改脚本自用

1. Fork 本仓库，保留 GPL-3.0 许可证和上游来源说明。
2. 需要改主镜像时，将 `po0.conf.example` 复制为 `po0.conf`。`PO0_MIRROR_BASE` 只能是 HTTP 主机和可选端口，不带路径；Debian 安装器依赖 HTTP 仓库路径。
3. 需要单独改 URL 时，将 `po0-mirrors.conf.example` 复制为 `po0-mirrors.conf`，每行两个 HTTP(S) 字面前缀，第一条匹配生效。例如将对应源映射到实际可用的 `http://YOUR-MIRROR:8080/` 服务。
4. 修改代码后重新构建完整 bundle 并上传。`po0.conf` 是受信任的 shell 配置；配置文件、密钥和实机日志不应提交到公开仓库。

日常验证命令：

```bash
python3 -m unittest discover -s tests -p 'test*.py'
busybox ash tests/test-network.sh
bash tests/test-trans.sh
sh tests/test-chrony.sh
bash tests/test-trans-chrony.sh
sh tests/test-cloud-transport.sh
bash tests/test-trans-cloud.sh
```

隔离测试和 CI 不会运行重装入口，不能代替真实清盘、启动和 SSH 验证。实机记录：[2026-10-27](docs/live-test-2026-10-27.md)、[2026-10-28](docs/live-test-2026-10-28.md)。

## 感谢

感谢 [bin456789/reinstall](https://github.com/bin456789/reinstall) 提供原始项目和文档。本分支基于 `01e1e259968c3b9c5ee5d6aea7253392b5eafe92`，已同步上游至 `54fae2067557b3c0ca49e7c9ce03bca63c793f8c`，沿用 [GPL-3.0](LICENSE)。未修改的上游说明备份见 [README.upstream.md](README.upstream.md)。

以下为原项目感谢的资源提供方，保留其原有署名，并非本分支的赞助或验证声明：

[![Oracle Cloud](https://github.com/bin456789/reinstall/assets/7548515/8b430ed4-8344-4f96-b4da-c2bda031cc90)](https://www.oracle.com/cloud/)
[![DartNode](https://github.com/bin456789/reinstall/assets/7548515/435d6740-bcdd-4f3a-a196-2f60ae397f17)](https://dartnode.com/)
