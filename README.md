# SSH-Launchpad OneClick（Remote-Onboarder）

[![CI](https://github.com/Shallow-dusty/remote-onboarder/actions/workflows/ci.yml/badge.svg)](https://github.com/Shallow-dusty/remote-onboarder/actions/workflows/ci.yml)

Windows x64 一键接入工具：把一台 Windows 机器配置好 OpenSSH、写入控制器公钥、
关闭 SSH 密码/键盘交互认证、将 SSH 防火墙限制到 Tailscale 地址范围、
安装 Tailscale 并用一次性密钥加入指定 Tailnet。全程终端实时显示进度，
结构化日志实时上传到自建的日志接收器（可选）。

面向「帮朋友配置机器」的一次性场景，刻意从简：不加密、不做多租户、
不做签名分发。健壮性优先——每一步都基于真实系统状态判断；正常完成后可重复检查，失败或中断时先确认恢复状态，不盲目重跑。
重复运行时若发现 sshd 服务存在但 `sshd.exe` 缺失（如被杀毒软件误隔离），
会在受支持的 MSI 路径上尝试修复；系统 capability 或陌生路径交由原安装方式处理，不先删除服务。

这是 [SSH-Launchpad](https://github.com/Shallow-dusty/ssh-launchpad)
（跨平台 GUI 引导工具）的极简 Windows 单文件产品线：不需要 WebView2 运行时、
不需要解压 ZIP，接收方拿到手的只是一个 EXE。

> 本轮审计改动尚未发布；代码内版本仍为 1.0.0。没有覆盖已有桌面 EXE。
> 已验证与未验证的范围见 [STATUS](STATUS.md)。

## 安全模型

- **公钥认证 only**：`PasswordAuthentication no`、`KbdInteractiveAuthentication no`
- **目标暴露范围仅限 Tailnet IPv4**：托管 TCP 22 规则固定为 `100.64.0.0/10`；同时检查有效入站策略和其他适用于 sshd 的放行规则。仅自动禁用明确的旧 OpenSSH TCP 22 宽规则，陌生规则需人工处理；本机检查不能证明远端一定可达。
- **密钥只在构建时注入**：Tailscale 一次性 key 与控制器公钥保存在本地
  `build/oneclick/private-config.json`（0600，gitignore），仓库里只有模板占位符
- **载荷签名校验**：构建时校验 Microsoft / Tailscale 官方 Authenticode 签名与 SHA-256
- 接收方操作只需：双击 EXE → UAC 点「是」→ 等完成 → 把桌面的
  `SSH-连接信息.txt` 发回来

## 目录结构

```text
payload/                 内嵌进 SFX 的脚本（模板，未含任何密钥）
  setup.ps1              主脚本：预检/安装/配置/接入/验证/日志上传
  safety.ps1             策略检查、凭据脱敏、恢复快照与路径保护
  bootstrap.ps1          提权包装器
  launcher.cmd           SFX 入口
log-receiver/            可自建的实时日志接收器（Go，静态单文件 + Docker）
scripts/
  build-oneclick-windows.sh   WSL 构建脚本：下载固定版 MSI → 注入私密配置 →
                              语法/签名/自检/解包比对 → IExpress 打包 → 桌面
docs/build.md            构建流程、运行时步骤、日志与服务器部署细节
AGENTS.md                仓库工作约定（安全契约与开发规范）
config.example.json      私密配置样例（真实配置放 build/oneclick/private-config.json，
                         0600 权限，永远不进 git）
```

## 构建（WSL）

前置：WSL + `jq` + Windows PowerShell 5.1 + IExpress（Windows 自带）。

```bash
mkdir -p build/oneclick
cat > build/oneclick/private-config.json <<'EOF'
{
  "tailscaleAuthKey": "tskey-auth-...",
  "publicKey": "ssh-ed25519 AAAA... controller",
  "expectedTailnet": "your-tailnet.ts.net",
  "logEndpoints": []
}
EOF
chmod 600 build/oneclick/private-config.json
./scripts/build-oneclick-windows.sh
```

字段说明：

- `tailscaleAuthKey`：Tailscale 管理台生成的一次性可复用/不可复用 auth key
- `publicKey`：控制器的 SSH 公钥（写入目标机 `authorized_keys`）
- `expectedTailnet`：目标 Tailnet 的 MagicDNS 后缀（如 `your-tailnet.ts.net`），
  用于核对连接的网络；这不是密钥泄漏防护。已有不同 Tailnet 或不明确状态会阻止自动切换。
- `logEndpoints`：可选，最多三个 HTTPS `POST /events` 地址；不接受 URL 内凭据、查询参数或重定向。留空 `[]` 完全跳过远程日志。接收器应由受保护的反向代理或私有网络隔离，不应公开。

构建器会自动：下载并锁定两个官方 MSI（校验 Microsoft / Tailscale Authenticode
签名）、注入私密配置、用 Windows PowerShell 5.1 做语法解析、跑无副作用自检
（哈希/幂等变换/临时文件 ACL；自检禁用远程日志）、IExpress 打包后不执行解包并逐文件比对，
最后放到 Windows 桌面。包含注入密钥的临时构建目录会在退出时删除。

仅验证、不打包 EXE、不覆盖桌面旧版本：

```bash
./scripts/build-oneclick-windows.sh build/oneclick/private-config.json --validate-only
```

新增审计与行为边界见 [`docs/audit-2026-09.md`](docs/audit-2026-09.md)。

## 实时日志（自建，可选）

`log-receiver/` 是配套的 Go 日志接收器（单二进制 + Dockerfile），协议：

- `POST /events`：接收结构化 JSONL 事件
- `GET /sessions`、`GET /sessions/{id}`：会话列表面板与回放
- `GET /healthz`：健康检查

日志服务器不可达不判定安装失败；请求有短超时与退避，仍可能短暂延迟步骤。事件本地排队，在本次运行的后续事件/退出时尝试续传（无常驻后台上传器）。部署细节见
`docs/build.md`。

## 内嵌载荷（锁定版本）

| 载荷 | 版本 | SHA-256 |
|---|---|---|
| Win32-OpenSSH x64 MSI | 10.0.0.0p2-Preview | `ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9` |
| Tailscale amd64 MSI | 1.102.3 | `03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce` |

## 文档

- [文档导航与排障顺序](docs/README.md)
- [当前状态和兼容性变化](STATUS.md)
- [变更记录](CHANGELOG.md)
- [构建、运行与部署边界](docs/build.md)
- [九月安全与交互审计](docs/audit-2026-09.md)

## License

[MIT](LICENSE)
