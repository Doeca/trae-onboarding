# Bash 版使用说明

## 改造范围

入口为 `bash onboarding.sh`，业务编排、HTTP、JSON、持久化及恢复使用 Bash + curl + jq + GPG，不调用 Python。原有 Python 版暂保留作为对照和回归测试，不是 Bash 的运行依赖。Magpie 自身的 Bun/plugin 运行时仍然必需，原有小型 JavaScript 出站保护也保留；不启动或操作浏览器。

Bash 版使用 **version 2 / engine bash** 的状态，拒绝读取旧 Python 状态，不能用新状态无脑重跑已处理过的企业。升级前核实旧批次是否还有未完成任务，原目录及状态保留，不自动迁移。

## 1. 交互环境验证与安装

在自己的本地终端运行：

```bash
bash onboarding.sh bootstrap
bash onboarding.sh doctor
```

`bootstrap` 会询问 Magpie 可执行文件位置、配置位置、Trae 插件位置及所需运行时位置，并要求明确确认；不会私自选系统路径或覆盖已有安装。原生插件安装目录由所选 Magpie 配置位置决定，脚本展示派生路径供确认，不假装支持原生命令不存在的任意目录选项。

Magpie 缺失时输入审核过的 HTTPS 独立可执行文件下载地址和 SHA256，先下载到专用临时目录再校验安装，**不执行 curl | sh**。当前仅支持已审核 manifest 中的二进制、Trae 插件及 Bun/宿主版本，不自动接受 latest。缺失已审核的运行时文件时暂停，不能把“插件安装成功”当成运行环境已经齐备。

依赖：Linux、Bash 4.4+、curl、jq、GPG，以及常见 coreutils/util-linux 工具（flock、timeout、setsid、sha256sum、sync、realpath 等）。缺少系统工具会报告缺失项，**不会自行 sudo 或调用包管理器**。完整安装行为与限制见 [环境安装说明](BASH-SETUP.md)。

交互安装在飞书桥接或没有控制终端时拒绝，不通过聊天收集本地路径。`doctor` 仅离线检查，不登录管理员、不创建账号；它不是企业在线权限检查。

## 2. 管理员配置

```bash
cp .env.example .env
chmod 600 .env
```

编辑 `.env`：

```dotenv
TRAE_ADMIN_ACCOUNT='你的企业管理员账号'
TRAE_ADMIN_PASSWORD='你的管理员密码'
```

只读取这两个键，不 source、不 eval、不展开 `$()` 或 shell 变量。环境变量同名值优先。引号内按字面值读取，含空格/`#` 的值需整体包在引号中；不支持行尾注释或 shell 转义拼接，避免不同解析规则误读密码。

`--env-file` 可指定其他文件。企业和根部门来自登录身份，不手写旧抓包中的 ID。新增成员固定 Full 普通成员，邮箱密码随机生成。

## 3. 在线检查与真实运行

先检查企业权限/配额（会登录管理员，但不创建成员）：

```bash
bash onboarding.sh check --state-dir ./tmp/bash-team
```

真实创建需两个明确接受标记，并使用前一步确认的配置位置：

```bash
bash onboarding.sh run --state-dir ./tmp/bash-team \
  --yes-fill-full-seats --accept-disposable-mailbox
```

完整顺序为环境复检 → 管理员校验 → 邮箱/邀请 → 收信验证 → 注册激活 → 原生 `magpie plugin login trae-cn` → 填满现有 Full 席位 → 全选当前插件目录模型 → 网关专用密钥配置。不会购买席位、删除成员或抢占无法控制的旧邀请。

默认网关密钥仅输出到本地控制终端。无人值守或 bridge 环境使用 `--skip-gateway`，之后在本地终端补做。不要 unset bridge 变量绕过保护。

| 参数 | 默认 / 说明 |
| --- | --- |
| `--state-dir` | `./tmp/bash-onboarding`；批次固定，不要换目录重试 |
| `--env-file` | `.env` |
| `--poll-seconds` | 15；整数 8–3600 |
| `--mail-timeout` | 180；整数 30–600 |
| `--login-timeout` | 120；整数 30–600；原生子进程最长存活时间 |
| `--watch` | 满员后继续进程内轮询 |
| `--retry-mail` | 为既有邀请重新开启收件等待；不重发邀请 |
| `--skip-gateway` | 暂缓网关配置和密钥输出 |
| `--gateway-lan` | 显式开启共享监听，会影响现有客户端/网络暴露 |
| `--gateway-url` | 要打印的外部 HTTP(S) Base URL；不配置 DNS/TLS/反向代理 |

Bash 版不使用 Python 的 `--magpie-default-config` / `--plugin` 参数；实际 Magpie 与插件位置由交互环境配置决定。当前网络安全读操作最多尝试两次，重试前带超时探活；写操作结果未知时暂停并在下次核对，不无限循环。

## 4. 恢复与网关

```bash
bash onboarding.sh status --state-dir ./tmp/bash-team
bash onboarding.sh publish-models --state-dir ./tmp/bash-team
bash onboarding.sh setup-gateway --state-dir ./tmp/bash-team
```

成员成功后后续步骤失败不回滚、不重复注册。网关新密钥先加密保存再注册，重跑核对相同密钥；限制验证完成前不显示。网关操作不是原子事务，失败可能留有尚未限模的密钥，不要自行复制未完成的密钥去使用。

正常网关输出仅写控制终端，stdout 状态不含密钥。模型范围为 `trae-cn/*`；本机回环访问可能被原生 Magpie 信任，不能把这个范围当作防御本机进程的安全边界。

**不会安装后台服务或保证网关一直在线。** 短时管理进程退出；长期服务应由同一用户/同一选定配置的 Magpie 提供。外部 URL 仅展示，不验证外网可达。公网访问自行配置 HTTPS、防火墙与访问控制。没有自动推理测试，不代表企业续期或模型权限已验证。

## 5. 状态安全与限制

持久化状态加密保存；运行中 HTTP Cookie、JSON 和临时凭证位于仅当前用户可访问的临时目录，正常退出清理。SIGKILL/断电可能留下临时明文，恢复前按敏感数据处理。密钥和密文都在同一机器，不等于硬件安全存储。

不导入旧 HAR、账号或实验凭证；原生 Magpie 自己的凭证仍按其格式保存。邀请 HTML 只提取允许域名下的链接，未知编码或接口结构暂停，不执行 HTML/JS。所有结构化响应由 jq 解析，不用正则拼 JSON。上游 ID 要求字符串，避免 jq 数字精度导致身份误配。

Bash 离线验证：

```bash
bash tests/shell/run.sh
```

覆盖环境确认/安装保护、超时重试、加密检查点、完整假接口链路、原生回调结构、模型与网关配置恢复。此轮不创建真实成员、不修改日常网关；离线通过不等于新版真实全链路已验证。
