# Bash 环境与安装模块

此模块只负责环境检查及本地交互安装配置，不会登录管理员、创建成员、打开浏览器、启动网关或验证模型推理。开发验证仅使用离线替身，没有执行真实安装。

## 调用接口

调用者先定义 `PROJECT`（仓库规范化绝对路径）、`TMP="$PROJECT/tmp"`，加载提供 `fail(reason)` / `emit(event)` 的公共模块，再 source `shell/bootstrap.sh`。`fail` 必须退出，事件及原因都是固定脱敏字符串。

- `bootstrap_interactive`：在子 shell 内完成交互、安装及保存；返回成功不改变父 shell 的路径变量。后续调用 `load_install_config`。
- `load_install_config`：严格读取 JSON，不使用 `eval` 或 source；导出 `magpie_bin`、`config_home`、`plugin_path`、`bun_path`、`host_path`，以及对应的 `MAGPIE_BIN`、`CONFIG_HOME`、`PLUGIN_PATH`、`BUN_PATH`、`HOST_PATH`。不导出/改变进程的 `XDG_CONFIG_HOME`，由原生适配器在其子进程中设置。
- `environment_check`：加载配置，检查依赖、实际文件、固定插件版本和运行时 SHA256。成功输出 `environment_ready`，不会启动原生程序或联网。

要求 Linux x86_64（glibc）和 Bash 4.4+。`bootstrap` 检测并补装缺失的 curl、jq、GPG、util-linux、coreutils、grep、diffutils、unzip 和 CA 证书。支持 Debian/Ubuntu 的 apt-get，以及 Fedora/RHEL/Rocky/AlmaLinux/CentOS 的 dnf/yum；其他发行版需自行准备系统工具。Bash 和发行版包管理器是启动前提，损坏的系统基础工具或缺失发行版签名密钥不会绕过检查。

安装前在本地终端显示缺失命令、包名、仓库和权限要求；非 root 用户同意后才调用 sudo。只使用发行版仓库并保留签名验证，不执行全系统升级。安装下载、缓存和事务日志放在项目 `tmp/dependencies.*`，系统包数据库、锁和软件包脚本仍会修改系统路径。失败后保留日志，不自动重试未知的安装事务。`doctor` 始终只检查，缺少配置时也不转入安装。

配置保存在项目 `tmp/shell-install.json`，仅含上述五个路径字段，文件要求当前用户所有、0600，`tmp` 要求当前用户所有且不允许组/其他用户访问（推荐 0700）。保存采用私有临时文件、sync、原子替换。现有目录权限不被自动修改；安装选择文件可在重新明确确认后替换，不覆盖现有 Magpie 可执行文件或插件。

## 本地交互与同意

只能在操作者本地控制终端执行 bootstrap。提示及路径只写入 `/dev/tty`，stdout 仅发出固定事件。无控制终端、存在任何 `LARK_CHANNEL*` 或 `LARKSUITE_CLI_CONFIG_DIR` 标记（包括空值）、开启 shell tracing 时拒绝。不要删除 bridge 标记绕过限制，不要录屏或将终端内容转发到群。

所有路径提示都会显示实际默认值，直接回车使用该值，也可输入自定义绝对路径；确认提示默认 `[YES]`，回车、`yes` 或 `y`（不区分大小写）表示同意，`no` 或其他输入取消。关闭输入（EOF）仍停止，不视为同意。Magpie 可执行文件优先使用已保存的选择，其次使用 PATH 中已安装的 Magpie；均不存在时使用官方 Linux 安装器默认的 `$HOME/.local/bin/magpie`（设置了 `MAGPIE_BIN_DIR` 时为 `$MAGPIE_BIN_DIR/magpie`）。配置位置默认 `${XDG_CONFIG_HOME:-$HOME/.config}`，Bun/宿主默认使用 `${XDG_CACHE_HOME:-$HOME/.cache}/magpie` 下对应的固定版本路径；已有保存值优先。

默认值在提示中展开为实际路径；手动输入仍必须为规范化绝对路径，不展开 `~`、环境变量或 shell 表达式。路径输入处回车选择默认路径；确认提示处回车表示同意提示中描述的操作。所选安装目录或 config home 不存在时，单独提示后创建；不跟随软链接，不接管其他用户所有或组/其他用户可写的目录。已有文件不自动覆盖或升级。

### Magpie 缺失

1. 指定一个不存在的可执行文件位置，其父目录须当前用户拥有且不可被组/其他用户写入。
2. URL 和 SHA256 提示默认填入已核实的 [Magpie v0.1.1364 CLI Linux amd64](https://github.com/yetone/magpie-releases/releases/tag/v0.1.1364) 发布文件及摘要，直接回车即可；可指定镜像 URL，但摘要仍必须匹配固定版本。
3. 明确同意下载和安装。

Magpie 下载固定独立 ELF，不运行安装脚本或使用 `curl | sh`。下载进入项目 tmp 下新建的空目录，验证 SHA256 和 ELF 标识后才复制到目标；所有网络请求有内外超时，只允许 HTTPS 重定向。临时网络错误先进行一次有界探测，再最多重试一次；HTTP 拒绝/校验错误不重试。目标创建使用排他创建，不覆盖已有文件或软链接。写入中断可能留下新的不完整目标，必须人工检查处理，不会自动覆盖重试。用户提供的 SHA256 必须同时等于下方已审核的 Magpie 固定清单，否则在联网/安装前拒绝。已有 Magpie 也必须匹配该清单，原生命令执行前再次检查。其他版本即使来自可信发布也不自动接受；升级必须重新审查并同时更新原生适配器和此模块的清单。

### Trae 原生插件

支持已观察到的原生 CLI 形式：

```text
magpie plugin add @magpie-community/opencode-trae-auth@0.2.26
```

先选择 `config_home`（**magpie 目录的父目录**，即传给原生命令的 `XDG_CONFIG_HOME`），物理入口由原生 npm 布局派生：

```text
<config_home>/magpie/plugins/node_modules/@magpie-community/opencode-trae-auth/index.mjs
```

这不是一个可随意配置的插件安装目录选项。模块检查包名、入口、精确版本 `0.2.26` 及插件入口的固定 SHA256。已有其他版本、损坏目录或不同原生布局会停止，须人工审查，不会隐式更新。自定义本地插件路径和不同 Magpie 版本的布局暂不支持。

插件缺失时，单独确认原生安装命令及其对注册表/依赖的更新。运行时间限制 180 秒（另加 5 秒终止宽限）；原生输出直接丢弃，不泄露安装路径或可能包含的敏感内容。命令使用清洁环境、已校验 Bun/host 的临时缓存及项目内临时目录，不会调用登录命令。失败/超时属于可能部分完成，须先核对原生配置，不盲目自动重试。原生包管理器仍负责下载与包安装；精确 npm 版本固定不是独立 SHA256 来源认证，也不是包执行沙箱。真实安装兼容性没有在此次开发中验证。

### 严格的已审核文件清单

Magpie、插件入口及 Bun / host 的固定清单在 `shell/bootstrap.sh` 和 `shell/native.sh` 中维护，两处必须保持一致。不要求 Python 运行时：

| 文件 | SHA256 |
| --- | --- |
| Magpie 可执行文件 | `f730747a84cc3932da6f6a84926cf428a10ee2224c5c6dfbf37df9dbfd4dffb6` |
| Trae 0.2.26 `index.mjs` | `df2eb4515bd4dd3a863006023385038a8c79eb09d1efe849fd14af979b810d1d` |
| Bun 1.4.4 (`magpie-bun`) | `10702245766b225e70bbf6235fd6b47214fd94b4760d00ffaed8ab0df57ac235` |
| `host-25ef7cf0d281.js` | `25ef7cf0d2813cc25a2e3675c28b5fa9ce9ec87f1b5a621803a193ab3929dbac` |

Bun 缺失时下载 [官方 1.4.4 Linux x64 baseline ZIP](https://github.com/oven-sh/bun/releases/tag/bun-v1.4.4)，校验归档和二进制摘要，只提取指定成员到私有临时文件，不按归档路径展开。宿主缺失时下载 [固定提交的原始 host.js](https://github.com/yetone/magpie/blob/dd1e8822d916f8aeb085db4db93fc3d79e2263ed/internal/plugin/host.js)，校验后原样保存，不通过运行登录、模型列表或网关来提取宿主。

已有但校验不匹配的文件仍停止，不擅自替换；只补装缺失文件。文件和其父目录软链接不受支持。不自动切换 latest，也不自动更改固定清单。这套清单仅支持 Linux x86_64/glibc，其他架构/运行库需单独审核；文件存在且匹配不等于企业登录、续期或模型调用已验证。

## 离线验证

```bash
bash tests/shell/test_bootstrap.sh
```

测试仅在项目 tmp 下使用合成文件、假 curl、假运行时哈希和假原生命令，不联网、不安装真实软件、不读取真实凭证。覆盖配置/权限/软链接校验、JSON 非执行解析、插件及运行时版本、依赖检查、非交互/bridge 拒绝、同意拒绝、下载校验及防覆盖、原生命令参数和输出脱敏。测试中替换终端函数只是测试替身，正式模块没有静默同意或输入文件后门。
