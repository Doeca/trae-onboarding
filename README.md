# Trae Full 席位 API 轮询脚本

## Bash 入口（不依赖 Python）

新版入口为 `bash onboarding.sh`，使用 Bash + curl + jq + GPG。先在本地终端运行 `bash onboarding.sh bootstrap`，交互确认安装与配置路径；再运行 `bash onboarding.sh doctor` 离线复检。缺失安装需要明确确认，不自行覆盖或升级。

完整步骤见 [Bash 使用说明](docs/BASH-USAGE.md) 和 [交互环境安装说明](docs/BASH-SETUP.md)。运行 `bash tests/shell/run.sh` 执行 Bash 离线测试。新版使用独立 v2 状态，不自动导入旧 Python 批次。

下文及 [原 Python 使用说明](docs/USAGE.md) 保留作为历史实现对照；Python 不是新版运行依赖。首次运行先复制 `.env.example` 为 `.env` 并填写自己的配置。

把管理员所在企业当前可用的 **Full 席位**逐个邀请、注册并激活，然后通过原生 `magpie plugin login trae-cn` 接入隔离的账号存储。不使用浏览器、不调用 `magpie-trae-login`、不修改已安装插件、不购买席位。

## 运行条件

- Python 3.11+、`requests`（见 requirements.txt）、GPG、curl、已安装的原生 Magpie 及 Trae 插件。
- 本地 `.env` 或环境中有 `TRAE_ADMIN_ACCOUNT` / `TRAE_ADMIN_PASSWORD`。仅解析这两个键，不执行配置文件。
- 仅对你有权管理的企业和现有席位运行。NiMail 是公共一次性邮箱，不保证独占或找回能力，运行前必须显式接受这个限制。
- Linux（使用进程组、flock 与本机 HTTP）。没有在其他系统验证。
- 原生适配器对本机已验证的 Bun 1.4.4 和宿主文件做 SHA256 固定校验，仅复制这两个运行时文件到隔离区，不复制真实账号。运行时缺失或升级后哈希变化会停止，需要重新审核并更新固定版本；不会自动下载替代品。

```bash
# 在项目根目录运行。先只检查管理员、部门、成员与席位；不会新增成员。
PYTHONDONTWRITEBYTECODE=1 python -m onboarding check

# 填满当前 Full 席位：逐个执行；满员后退出。
PYTHONDONTWRITEBYTECODE=1 python -m onboarding run \
  --yes-fill-full-seats --accept-disposable-mailbox

# 常驻：满员后继续轮询，未来出现空闲 Full 席位时继续填补。
PYTHONDONTWRITEBYTECODE=1 python -m onboarding run \
  --yes-fill-full-seats --accept-disposable-mailbox --watch

# 查看脱敏进度。不会展示密码、凭证或邀请链接。
PYTHONDONTWRITEBYTECODE=1 python -m onboarding status
```

### 明确写入日常 Magpie 配置

用户授权后可添加 `--magpie-default-config`：原生命令直接使用日常账号存储，不是把测试文件复制过去。建议为该模式使用独立的业务状态目录，避免与先前隔离运行的完成记录混用。例如：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding run \
  --state-dir ./tmp/default-config-live --magpie-default-config \
  --yes-fill-full-seats --accept-disposable-mailbox
```

此模式不修改已安装插件或注册表，给原生登录及短时模型管理子进程加载出站保护；其他账号保留。账号保存后，日常 Magpie 及其既有代理策略可以看到它们，后续常规使用不受本次出站保护约束，续期/模型能力仍未验证。2026-10-31 此模式已真实完成两个新成员从邮箱邀请到默认账号存储的接入，Full 激活数达到 4/4。

参数：`--poll-seconds` 默认 15（最少 8），`--mail-timeout` 默认 180，`--login-timeout` 默认 120，`--network-retries` 默认 3。`--state-dir` 默认 `./tmp/full-seat-onboarding`，只能位于项目 `./tmp` 内；重启务必使用同一个状态目录。`--plugin` 可指定实际安装的 Trae 插件目录。正常完成退出 0；暂停/失败退出 1；中断退出 130。

**开发完成不等于已执行填满真实席位。** `check` 会建立管理员登录会话；`run` 会创建真实邀请/成员并使用现有席位。持续运行须由你在终端或受控进程管理器中启动；脚本本身不安装服务或定时任务。

## 轮询与恢复

1. 校验管理员身份，并绑定首轮确认的企业 ID。之后企业变化立即暂停。
2. 查询当前根部门，遍历各部门成员分页，按用户 ID 去重。
3. 读取 Full 配额，扣除已占用以及尚未激活的邀请。成员列表已确认激活但配额延迟时采用保守计数。Work 席位不参与。
4. 优先恢复已有任务；没有未完成任务才创建一个新的邮箱。随机密码先加密持久化。
5. 根部门添加 `RoleID=3`、`AccountType=1`、`SendInvite=true` 的单成员邀请。
6. 邮箱有限轮询、核验邀请邮箱和企业，API 注册，核对激活状态。
7. 启动原生 Magpie，实时读取当次登录信息；完成企业 API 登录及凭证交换；按捕获页面原有结构执行本机 HTTP 交接。
8. 必须命令退出 0 且新凭证对实际保存，才标为完成。**不额外映射/展平企业身份字段**；缺失用户 ID 或租户字段只作为已知限制。
9. 重新查配额，继续下一个；满员由 Full `ActiveCount == TotalQuota` 判断，不把邀请成功当作激活成功。
10. 全部成员任务完成且 Full 席位全部激活后，启用当前配置中全部 `trae-cn` 模型并校验选择结果。默认隔离模式只处理隔离配置，`--magpie-default-config` 模式处理日常配置，不跨配置发布。
11. 默认执行网关收尾，配置专用访问密钥并仅向本地控制终端输出地址及密钥，然后报告整体完成。`--skip-gateway` 可暂缓这一步，之后用 `setup-gateway` 补做；不会自动安装服务或开放公网监听。

“持续轮询”不是无条件无限重试：网络读操作先探活、有限重试；鉴权/业务错误、人工验证、不可解释的状态暂停。外部已有邀请可能预留剩余席位，但脚本不拥有它们的邮箱或密码；这时暂停，不虚报满员，也不删除或重发别人的邀请。

- 邀请/注册等写入请求超时属于结果未知，不能盲目重发。先查上游成员列表；仍不能确认就暂停，保留检查点。
- 激活成功后 Magpie 失败，不回滚成员。相同启动命令会恢复该成员；先检查已有保存凭证，避免重复接入。
- 模型启用失败单独记录 `model_publication=FAILED`，已完成成员不回退；用相同命令重跑会重新校验并尝试模型步骤，不因模型步骤失败重复邀请或注册。`status` 会显示这个独立检查点。常驻模式每轮满员时也会重新处理模型目录。模型可见不等于推理成功，本步骤不发送推理请求。
- 邀请邮件等待超时后，同一命令增加 `--retry-mail` 可以为既有邀请重新开启一次收信等待，不重发邀请、不创建替代成员。公共邮箱恢复能力不保证。
- `Ctrl-C` / SIGTERM 停止后续步骤并关闭子进程，不删除成员、邮箱或凭证。
- 全项目排他锁避免脚本多实例抢占；无法阻止其他管理员并发操作，服务端仍是配额最终裁决者。

## 全模型对外展示

收尾步骤通过原生 Magpie 的本机管理 API，对 `trae-cn` 执行显式全选，关闭该提供商的 `noModels` / `unlisted`，随后读取确认。不会依赖自动目录默认的 24 个模型上限；无 API 的模型不新选，已有选择不删除。保留其他提供商选择、代理、限流、上下文覆盖及现有 agent / gateway-key 的访问限制；这些限制仍可能让特定客户端只看到子集。

管理 API 由短时 `magpie web --no-open` 子进程提供，仅绑定回环地址；程序直接发送 HTTP，不启动或操作浏览器，完成后关闭子进程。不调用上游目录刷新或模型推理。插件目录为空/不支持时暂停，不虚报成功；并发编辑检测到变化也暂停，运行时请勿同时编辑模型设置。

已有完成记录可以单独补做模型步骤，不登录管理员、不创建成员，也不重新确认企业当前配额：

```bash
PYTHONDONTWRITEBYTECODE=1 python -m onboarding publish-models \
  --state-dir ./tmp/default-config-live --magpie-default-config
```

正常 `run` 已自动包含这一步，无需另加开关。只覆盖执行时当前目录中的模型；常驻模式下一次满员轮询会纳入后续新增模型。

2026-10-31：日常配置的当前插件目录 6 个模型已显式全选；重复执行无额外写入。现有网关 `/v1/models` 返回的 33 个 `trae-cn/` 条目包含这 6 个，但网关目录与当前插件目录不完全一致，不据此宣称其余 27 个已通过本步骤启用或验证。未发送模型推理请求。

## 凭证和隔离边界

状态保存在 `./tmp/full-seat-onboarding/state.gpg`，包含邮箱、密码、最新凭证对、检查点。采用 GPG AES256，加密密钥单独保存在受限 `keys` 子目录；目录 0700、文件 0600，原子替换并 fsync。**密钥与密文仍在同一台机器，不等于硬件密钥库；持有完整目录的人可以解密。** 不把这些文件加入版本控制，不丢失密钥，不使用公开共享目录。

Magpie 的原生账号文件位于专用隔离目录 `native/config/magpie/plugin-auth.json`，由宿主以自身格式写入，**是受权限保护的明文，不是加密凭证库**。这是原生宿主持久化的明确限制；不要把整个运行目录当成无敏感信息的临时文件删除或分享。JSONL 运行日志只输出业务状态，不输出原生 stdout、回调 URL、密码或 Token。用户明确要求的网关地址/密钥只写入 `/dev/tty`，不进入 stdout 日志；桥接群聊或无本地终端时拒绝该步骤，须 `--skip-gateway` 后在本地补做。

隔离插件入口只加载原有插件并阻止插件出站 `fetch`。这是为了防止它把企业凭证发送到消费版设备刷新接口，亦会阻止目录查询。没有修改原始插件或伪造登录成功；真实账号保存仍由原生宿主完成。**此实现验证并编排登录/保存及当前插件目录的模型选择，不验证续期、模型调用或生产代理可用性；不将隔离账号自动合并进现有生产配置。**

## 离线测试

```bash
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -v
PYTHONDONTWRITEBYTECODE=1 python -m onboarding --help
```

测试使用脱敏结构和假客户端/子进程，不读取 HAR 凭证，不访问真实服务。测试临时文件仅位于 `./tmp`。真实历史单成员实验与本次实现的离线测试是不同证据，完整新脚本填满席位的端到端行为尚需显式授权执行。
