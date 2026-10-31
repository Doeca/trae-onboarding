# 使用说明

## 1. 准备环境

在仓库根目录运行命令。需要 Linux、Python 3.11+、GPG、curl、原生 Magpie，以及已安装的 Trae 插件。

```bash
python -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
chmod 600 .env
```

使用本地编辑器修改 `.env`，不要把真实密码直接写入公开聊天、Git 或命令历史：

```dotenv
TRAE_ADMIN_ACCOUNT='你的企业管理员账号'
TRAE_ADMIN_PASSWORD='你的管理员密码'
```

环境中同名变量优先于 `.env`。文件只读取这两个键，不执行 shell。密码含空格、`#` 等字符时保留引号；含单引号时可使用双引号。不要把 `.env.example` 的占位值当作真实配置。

原生运行时目前固定为审核过的 Bun 和宿主版本，路径/哈希在适配器中定义。换机器或升级运行时时需重新审核，不要删除校验绕过错误。这不是能任意版本直接运行的通用安装器。

## 2. 必须理解的参数

| 参数 | 默认 / 用途 | 是否要修改 |
| --- | --- | --- |
| `TRAE_ADMIN_ACCOUNT` | 企业管理员账号 | 必填 |
| `TRAE_ADMIN_PASSWORD` | 对应密码 | 必填 |
| `--env-file` | `.env` | 使用其他配置文件时修改 |
| `--magpie-default-config` | 不加时写隔离配置 | 要让日常 Magpie 使用新增账号时加上 |
| `--state-dir` | `./tmp/full-seat-onboarding` | 推荐为批次固定一个目录；重跑必须相同 |
| `--plugin` | 当前用户配置下已安装的 Trae 插件 | 安装位置不同时修改 |
| `--poll-seconds` | 15 秒，范围 8–3600 | 控制席位查询间隔 |
| `--mail-timeout` | 180 秒，范围 30–600 | 邮件慢时提高 |
| `--login-timeout` | 120 秒，范围 30–600 | 原生登录或本机管理启动慢时提高 |
| `--network-retries` | 3，范围 0–10 | 临时网络故障重试预算 |
| `--skip-gateway` | 默认不跳过网关收尾 | 无交互终端/暂不配置网关时添加 |
| `--gateway-lan` | 默认保持原生监听设置 | 明确需要启用共享时添加；注意网络暴露 |
| `--gateway-url` | 默认原生网关本机地址 | 已部署反向代理、需要打印外部地址时修改 |
| `--watch` | 不加时满员后退出 | 希望以后空出席位自动继续填补时添加 |
| `--retry-mail` | 默认不重置收件等待 | 同一邀请邮件等待超时后手动添加 |
| `--yes-fill-full-seats` | 显式授权使用全部现有空闲 Full 席位 | 真实 `run` 必填 |
| `--accept-disposable-mailbox` | 接受公共一次性邮箱及无法找回风险 | 真实 `run` 必填 |

不需要写死企业 ID、部门 ID 或成员邮箱密码：企业/根部门来自管理员当前响应；成员为 Full 普通成员（RoleID 3、AccountType 1），邮箱及密码逐个随机生成并加密保存。不会购买席位、删除已有成员或替其他管理员处理无法控制的邀请。

## 3. 检查与运行

先检查管理员、企业及席位。此操作会登录管理员，但不创建成员：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding check \
  --env-file .env --state-dir ./tmp/team-batch
```

在自己的本地交互终端执行真实流程，接入日常 Magpie：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding run \
  --env-file .env --state-dir ./tmp/team-batch \
  --magpie-default-config \
  --yes-fill-full-seats --accept-disposable-mailbox
```

不要在群机器人里直接运行需要显示密钥的命令。敏感终端输出不要录屏、粘贴到群或纳入日志收集。

正常流程：查询席位 → 分配邮箱 → 邀请 → 收信及验证 → 注册/激活 → 原生 Magpie 登录/保存 → 重复至满员 → 全选当前 `trae-cn` 模型 → 网关收尾。

`--watch` 是进程内轮询，不是安装定时任务；进程停止后不会继续执行。

## 4. 进度与恢复

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding status --state-dir ./tmp/team-batch
```

进度命令不输出密码、Token 或网关密钥。失败后优先使用同一命令、同一状态目录恢复，不删除状态重新运行。激活完成但后续步骤失败不会回滚成员。网络写入结果未知时先核对再继续，不能靠无限重试解决。

仅补做模型发布，不新增成员：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding publish-models \
  --state-dir ./tmp/team-batch --magpie-default-config
```

新仓库没有复制旧实验的真实状态或凭证。不能把新仓库的空状态目录误认为旧批次的恢复记录；迁移必须单独安全处理，并确认使用同一个 Magpie 配置。

## 5. 网关配置、地址与密钥

默认 `run` 会在成员全部完成、模型发布成功之后执行网关配置。也可以先加 `--skip-gateway` 完成账号流程，再在本地交互终端补做：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding setup-gateway \
  --state-dir ./tmp/team-batch --magpie-default-config
```

此命令要求同一批次的成员和模型步骤已完成，不登录管理员，也不创建成员。输出示意（密钥由程序生成，不使用下面占位值）：

```text
Base URL: http://127.0.0.1:3425/v1
API key: <程序生成的密钥>
Key model scope: trae-cn/*
```

密钥注册和模型限制是两个原生 API 操作，不是原子事务；如果中途失败，可能留下尚未限模的新密钥。该密钥在限制确认前不会输出，使用同一状态重跑可补完；不要另从 Magpie 界面复制未完成的密钥投入使用。

密钥不是企业管理员密码，也不是模型上游 Token。脚本先将生成的密钥保存到加密检查点，再用原生 API 注册、限制为 `trae-cn/*` 并回读验证，最后向 `/dev/tty` 输出。重跑会复用本批次密钥而不是不断创建；被人工禁用、删除或轮换的密钥会暂停，不能静默恢复权限。原生 Magpie 自己的密钥存储方式不由本脚本加密。

- **不会把密钥写入 stdout JSONL、普通状态输出或群回复**。无控制终端、在 bridge 中运行时默认提前拒绝，避免先创建账号后才发现无法安全输出。无人值守运行可加 `--skip-gateway`，之后在本地运行 `setup-gateway`。不要 unset bridge 环境变量绕过保护。
- 默认不改变监听范围；已有共享网关保持原状。Magpie 的回环访问可能信任客户端而不校验密钥，因此不能把本机地址/模型限制当作对本机进程的安全边界。
- `--gateway-lan` **显式打开原生网关共享**，可能让已有端口监听所有网卡，并影响已有所有客户端；仅在清楚网络边界时使用。新密钥限制校验通过后才执行这个开关。不会撤销既有其他密钥。
- `--gateway-url https://gateway.example.com/v1` 仅指定打印给客户端的外部地址，不修改监听端口、不配置 DNS、反向代理、TLS 或防火墙。默认打印原生 API 返回的本机网关地址，不自动推断公网 IP。
- 配置完成不等于服务运行。短时管理进程会关闭；长期网关需由你已部署的 Magpie 进程提供，或在同一用户、同一配置环境的另一个终端运行 `magpie serve`。脚本不安装 daemon，不启动脱离监管的后台进程。
- 若省略 `--magpie-default-config`，修改的是隔离配置，不能直接用日常 `magpie serve` 当作这套隔离网关。日常对外使用推荐默认配置模式；隔离模式用于验证，不自动部署长期服务。
- `MAGPIE_ADDR` 等服务进程环境覆盖可能改变实际地址；打印地址要与你长期运行的网关环境一致。脚本不修改已运行进程的环境，也不验证外网连通性。
- 经公网转发使用密钥必须配置 HTTPS 和访问控制。禁止在不可信 HTTP 链路发送密钥；修改前确认现有其他网关密钥权限。

远程地址示例（先自行部署 HTTPS 代理，再在自己的终端执行）：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding setup-gateway \
  --state-dir ./tmp/team-batch --magpie-default-config \
  --gateway-lan --gateway-url https://gateway.example.com/v1
```

客户端填写终端显示的 Base URL 和 API key；选择 `trae-cn/<模型ID>`。本脚本不发送推理请求验证，不保证续期或上游权限。`gateway_configured` 只代表配置和密钥作用域已经回读确认，`service_started=false` 明确表示没有启动长期服务。

## 6. 数据与验证边界

- `.env`、`tmp/`、HAR 和 Python 缓存均被 Git 忽略；示例文件没有真实秘密。
- 加密状态包含成员密码/凭证；密钥也在本机，不能抵御整台机器被读取。Magpie 原生凭证遵循其存储格式，不因此变成加密文件。
- 原生登录和短时管理子进程有插件 fetch 保护；常规网关服务没有这一保护。企业账号续期、推理权限及真实模型调用未验证。
- 模型列表可见不等于推理成功；程序不自动发送付费模型请求。
- 公共邮箱不保证独占及后续找回；风控、交互验证或未知业务错误会暂停，不使用浏览器绕过。

离线测试（不会新增账号或发出真实推理）：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -v
```
