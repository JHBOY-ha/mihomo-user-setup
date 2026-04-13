# mihomo-user-setup

面向 Linux 用户环境的 `mihomo` 一键部署与管理脚本。无需 `root` 权限，使用用户级 `systemd` 运行 `mihomo`，支持订阅拉取、开机自启、崩溃自动重启、Dashboard UI 下载，以及终端代理快捷命令。

适合这样的场景：

- 没有系统级安装权限，只能在当前用户目录下部署
- 希望用 `systemd --user` 管理 `mihomo`，而不是手动后台运行
- 需要把代理配置、订阅更新、状态查看、日志追踪统一到一个脚本里

## 特性

- 用户级安装：二进制安装到 `~/.local/bin/mihomo`
- 用户级服务管理：自动创建 `systemd --user` 服务
- 自动下载最新版本 `mihomo`
- 自动下载 Geo 数据：`geoip.dat`、`geosite.dat`、`country.mmdb`
- 自动下载 Dashboard UI：`metacubexd`
- 订阅管理：保存订阅、拉取配置、自动 Base64 解码
- 配置修补：自动覆写端口、Dashboard 地址、`secret`、`external-ui`
- 服务控制：启动、停止、重启、查看状态、实时日志
- 自启支持：可启用用户级开机自启，并检测 `linger`
- Shell 快捷命令：写入 `proxy1_on`、`proxy1_off`、`proxy1_status`

## 工作方式

脚本默认将所有运行文件写入当前用户目录：

- 二进制：`~/.local/bin/mihomo`
- 工作目录：`~/.mihomo`
- 配置文件：`~/.mihomo/config/config.yaml`
- 订阅链接：`~/.mihomo/.subscription`
- 环境配置：`~/.mihomo/.env`
- systemd 服务：`~/.config/systemd/user/mihomo.service`

安装完成后，`mihomo` 由用户级 `systemd` 接管，具备以下行为：

- 通过 `Restart=on-failure` 自动拉起异常退出的进程
- 支持 `systemctl --user enable mihomo` 实现登录后自启
- 如果管理员启用了 `linger`，则用户退出登录后服务仍可继续运行

> [!IMPORTANT]
> 该项目面向使用 `systemd` 的 Linux 环境。若系统没有用户级 `systemd`，例如部分容器环境、WSL1 或特殊精简系统，脚本无法正常安装和管理服务。

## 环境要求

- Linux
- `bash`
- `curl`
- `tar`
- `gzip` / `gunzip`
- `awk`
- `systemctl --user`
- 可访问 GitHub Releases 或可用的 GitHub 代理

建议确认以下命令可正常使用：

```bash
systemctl --user status
echo "$XDG_RUNTIME_DIR"
```

## 快速开始

### 1. 下载脚本

```bash
git clone <仓库地址>
cd mihomo-user-setup
chmod +x mihomo-user-setup.sh
```

如果你只是拿到单个脚本文件，也可以直接执行，无需额外项目结构。

### 2. 安装 mihomo

```bash
bash mihomo-user-setup.sh install
```

安装阶段会完成这些事情：

- 检测系统架构
- 获取 `mihomo` 最新版本
- 下载并安装二进制到 `~/.local/bin`
- 询问并保存代理端口与 Dashboard 密钥
- 创建用户级 `systemd` 服务
- 下载 Geo 数据和 Dashboard UI
- 向 shell 配置文件写入代理快捷命令

### 3. 设置订阅

```bash
bash mihomo-user-setup.sh sub "<你的订阅链接>"
```

该命令会保存订阅地址，并立即拉取配置。若订阅内容是 Base64 编码，脚本会尝试自动解码。

> [!TIP]
> 如果订阅链接里包含 `&` 查询参数，必须用单引号或双引号包起来；脚本现在也会检测疑似被 shell 截断的链接并直接提示重新输入。

### 4. 启动服务

```bash
bash mihomo-user-setup.sh start
```

启动成功后，脚本会输出 HTTP、SOCKS5、混合代理和 Dashboard 地址。

### 5. 启用开机自启

```bash
bash mihomo-user-setup.sh enable
```

> [!NOTE]
> 如果没有启用 `linger`，服务只会在当前用户登录期间运行。若希望退出登录后仍继续运行，需要管理员执行：
>
> ```bash
> sudo loginctl enable-linger <你的用户名>
> ```

## 默认端口

脚本默认使用以下端口，避免与常见系统级 `7890` 端口冲突：

| 类型 | 默认端口 |
| --- | --- |
| HTTP | `17890` |
| SOCKS5 | `17891` |
| Mixed | `17892` |
| Dashboard Controller | `19090` |

这些值会在安装阶段写入 `~/.mihomo/.env`，后续订阅更新时会自动重新应用。

## 常用命令

```bash
bash mihomo-user-setup.sh install
bash mihomo-user-setup.sh sub "<URL>"
bash mihomo-user-setup.sh sub-update
bash mihomo-user-setup.sh start
bash mihomo-user-setup.sh stop
bash mihomo-user-setup.sh restart
bash mihomo-user-setup.sh enable
bash mihomo-user-setup.sh disable
bash mihomo-user-setup.sh status
bash mihomo-user-setup.sh log
bash mihomo-user-setup.sh uninstall
```

命令说明：

| 命令 | 说明 |
| --- | --- |
| `install` | 安装 `mihomo`、创建服务、下载附属资源 |
| `sub <URL>` | 保存订阅链接并立即拉取配置 |
| `sub-update` | 重新拉取订阅配置 |
| `start` | 启动 `mihomo` |
| `stop` | 停止 `mihomo` |
| `restart` | 重启 `mihomo` |
| `enable` | 启用用户级开机自启 |
| `disable` | 关闭用户级开机自启 |
| `status` | 查看运行状态、自启状态与端口信息 |
| `log [N]` | 查看实时日志，默认最近 `50` 行 |
| `uninstall` | 删除服务、二进制、配置和数据 |

## 终端代理快捷命令

安装时，脚本会向 `~/.bashrc` 或 `~/.zshrc` 追加以下函数：

- `proxy1_on`
- `proxy1_off`
- `proxy1_status`

重新加载 shell 配置后即可使用：

```bash
source ~/.bashrc   # 或 source ~/.zshrc
proxy1_on
curl -I https://www.google.com
proxy1_off
```

`proxy1_on` 会自动读取 `~/.mihomo/.env` 中的 `MIXED_PORT`，并设置：

- `http_proxy`
- `https_proxy`
- `all_proxy`
- `HTTP_PROXY`
- `HTTPS_PROXY`
- `ALL_PROXY`
- `no_proxy`

## Dashboard

脚本会尝试下载 `metacubexd` 到本地目录，并把 `external-ui` 写入配置文件。默认情况下可通过以下地址访问：

```text
http://127.0.0.1:19090/ui
```

如果本地 UI 下载失败，脚本会提示使用在线面板：

```text
https://metacubex.github.io/metacubexd/
```

## 订阅更新与配置修补

每次执行 `sub` 或 `sub-update` 时，脚本会：

1. 下载订阅配置
2. 在必要时尝试 Base64 解码
3. 备份旧配置为 `config.yaml.bak`
4. 覆写关键字段，确保本地运行环境一致

自动修补的字段包括：

- `port`
- `socks-port`
- `mixed-port`
- `external-controller`
- `secret`
- `allow-lan: false`
- `external-ui`

这意味着即使你的订阅配置自带其他端口设置，脚本也会以本地保存的端口配置为准。

## 日志与排障

查看状态：

```bash
bash mihomo-user-setup.sh status
```

查看实时日志：

```bash
bash mihomo-user-setup.sh log
```

常见问题：

### 用户级 systemd 不可用

出现这类报错时，通常说明当前环境不支持或未正确初始化 `systemd --user`：

- 当前系统不是 `systemd`
- 通过 `su` 切换用户导致用户会话环境不完整
- `XDG_RUNTIME_DIR` 未正确设置

优先检查：

```bash
systemctl --user status
echo "$XDG_RUNTIME_DIR"
loginctl show-user "$(whoami)"
```

### 退出登录后服务停止

这是因为未启用 `linger`。需要管理员执行：

```bash
sudo loginctl enable-linger <你的用户名>
```

### GitHub 下载失败

脚本内置了多个 GitHub 代理前缀，会自动依次尝试。如果仍然失败，通常是网络连接问题，或者代理源不可用。可以根据实际网络环境修改脚本中的 `GITHUB_PROXY_LIST`。

## 卸载

```bash
bash mihomo-user-setup.sh uninstall
```

卸载会删除：

- `~/.local/bin/mihomo`
- `~/.mihomo`
- `~/.config/systemd/user/mihomo.service`
- shell 配置中由脚本写入的 `proxy1_*` 函数

## 项目结构

```text
.
├── mihomo-user-setup.sh
└── README.md
```

如果你希望在没有 `root` 权限的机器上快速部署一个可维护、可自启、可更新的 `mihomo` 用户实例，这个脚本就是为这个目标设计的。

## 相关仓库

本项目在运行过程中会直接使用或下载以下上游项目的发布内容：

- `MetaCubeX/mihomo`：核心二进制程序
- `MetaCubeX/meta-rules-dat`：Geo 数据文件，包含 `geoip.dat`、`geosite.dat`、`country.mmdb`
- `MetaCubeX/metacubexd`：本地 Dashboard UI
