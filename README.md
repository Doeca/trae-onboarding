# Trae Full 席位 API 轮询脚本

使用 Bash + curl + jq + GPG，将管理员所在企业当前可用的 **Full 席位**逐个邀请、注册并激活，再通过原生 `magpie plugin login trae-cn` 接入所选 Magpie 配置。不使用浏览器、不购买席位。仓库仅保留 Bash 实现，不依赖 Python。

## 环境与配置

需要 Linux、Bash 4.4+、curl、jq、GPG 和常见 GNU/coreutils/util-linux 工具，以及审核版本的原生 Magpie、Trae 插件和 Bun/宿主运行时。当前不支持任意版本或 macOS 原生运行环境。

在自己的本地终端执行：

```bash
bash onboarding.sh bootstrap
bash onboarding.sh doctor
cp .env.example .env
chmod 600 .env
```

`bootstrap` 交互确认安装与配置路径；缺失安装需要明确同意，不自行覆盖或升级。`doctor` 仅离线检查，不登录管理员、不创建成员。编辑 `.env` 填入自己的 `TRAE_ADMIN_ACCOUNT` 和 `TRAE_ADMIN_PASSWORD`，不要将真实凭证放入 Git 或聊天。

完整参数、恢复步骤和已知限制见 [Bash 使用说明](docs/BASH-USAGE.md)，安装约束见 [交互环境安装说明](docs/BASH-SETUP.md)。

## 检查与运行

仅对你有权管理的企业和现有席位运行。NiMail 为公共一次性邮箱，不保证独占或找回能力。

```bash
# 在线检查：会登录管理员，但不创建成员。
bash onboarding.sh check --state-dir ./tmp/bash-team

# 真实创建成员并使用当前空闲 Full 席位，需要明确授权。
bash onboarding.sh run --state-dir ./tmp/bash-team \
  --yes-fill-full-seats --accept-disposable-mailbox

# 查看脱敏进度。
bash onboarding.sh status --state-dir ./tmp/bash-team
```

`--watch` 可在满员后继续进程内轮询；脚本不会安装服务或定时任务。无本地控制终端或 bridge 环境运行时使用 `--skip-gateway`，之后在本地终端补做网关配置。

## 恢复与安全边界

- 批次使用固定的 `--state-dir`，失败后使用同一目录恢复。邀请、注册或账号写入结果未知时，先核对再重试；激活完成后模型发布或网关失败不会重复创建成员。
- 使用独立 **version 2 / engine bash** 状态，不自动导入旧 Python v1 状态。旧批次的状态及凭证需保留并核对，不要用空状态目录重复处理已完成的企业。
- 状态和临时文件只保存在项目 `./tmp`；加密密钥与密文位于同一机器，不能抵御整台机器被读取。中断可能留下临时明文，Magpie 原生凭证按自身格式保存，不要分享运行目录。
- 网关密钥只输出到本地控制终端，不写 stdout、日志或群聊。保留 bridge 环境变量，不绕过终端保护。
- 模型可见、原生登录成功或网关配置成功均不等于推理、续期或长期服务已验证。脚本不发送付费推理请求，不自动部署长期网关服务。

已有批次可单独补做收尾，不重新创建成员：

```bash
bash onboarding.sh publish-models --state-dir ./tmp/bash-team
bash onboarding.sh setup-gateway --state-dir ./tmp/bash-team
```

## 离线测试

```bash
bash tests/shell/run.sh
```

测试使用合成数据和假客户端，不读取真实凭证、不创建真实成员、不修改线上网关。`onboarding/network_guard.mjs` 是 Bash 原生适配器使用的 JavaScript 出站保护，并非 Python 实现。
