# SSH-Launchpad OneClick（Remote-Onboarder）

Windows x64 一键接入工具：把一台 Windows 机器配置好 OpenSSH、写入控制器公钥、
关闭 SSH 密码/键盘交互认证、将 SSH 防火墙限制到 Tailscale 地址范围、
安装 Tailscale 并用一次性密钥加入指定 Tailnet。全程终端实时显示进度，
结构化日志实时上传到自建的日志接收器（可选）。

面向「帮朋友配置机器」的一次性场景，刻意从简：不加密、不做多租户、
不做签名分发。健壮性优先——每一步都基于真实系统状态判断，可安全重跑。
重复运行时若发现 sshd 服务存在但 `sshd.exe` 缺失（如被杀毒软件误隔离），
会自动修复性重装 OpenSSH。

这是 [SSH-Launchpad](https://github.com/Shallow-dusty/ssh-launchpad)
（跨平台 GUI 引导工具）的极简 Windows 单文件产品线：不需要 WebView2 运行时、
不需要解压 ZIP，接收方拿到手的只是一个 EXE。

## 安全模型

- **公钥认证 only**：`PasswordAuthentication no`、`KbdInteractiveAuthentication no`
- **防火墙仅限 Tailnet**：TCP 22 入站规则固定为 `100.64.0.0/10`，公网/局域网均不可达
- **密钥只在构建时注入**：Tailscale 一次性 key 与控制器公钥保存在本地
  `build/oneclick/private-config.json`（0600，gitignore），仓库里只有模板占位符
- **载荷签名校验**：构建时校验 Microsoft / Tailscale 官方 Authenticode 签名与 SHA-256
- 接收方操作只需：双击 EXE → UAC 点「是」→ 等完成 → 把桌面的
  `SSH-连接信息.txt` 发回来

## 目录结构

```text
payload/                 内嵌进 SFX 的脚本（模板，未含任何密钥）
  setup.ps1              主脚本：预检/安装/配置/接入/验证/日志上传
  bootstrap.ps1          提权包装器
  launcher.cmd           SFX 入口
log-receiver/            可自建的实时日志接收器（Go，静态单文件 + Docker）
scripts/
  build-oneclick-windows.sh   WSL 构建脚本：下载固定版 MSI → 注入私密配置 →
                              语法/签名/自检/解包比对 → IExpress 打包 → 桌面
docs/build.md            构建流程、运行时步骤、日志与服务器部署细节
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
  脚本会用它核对设备加入的网络，防止 key 泄漏后被用于其他 Tailnet
- `logEndpoints`：可选。自建日志接收器的 `POST /events` 地址数组；留空 `[]`
  则完全跳过远程日志

构建器会自动：下载并锁定两个官方 MSI（校验 Microsoft / Tailscale Authenticode
签名）、注入私密配置、用 Windows PowerShell 5.1 做语法解析、跑无副作用自检
（哈希/幂等变换/ACL/日志上传链路）、IExpress 打包后不执行解包并逐文件比对，
最后放到 Windows 桌面。

## 实时日志（自建，可选）

`log-receiver/` 是配套的 Go 日志接收器（单二进制 + Dockerfile），协议：

- `POST /events`：接收结构化 JSONL 事件
- `GET /sessions`、`GET /sessions/{id}`：会话列表面板与回放
- `GET /healthz`：健康检查

日志服务器不可达时不阻塞安装，事件本地排队续传。部署细节见
`docs/build.md`。

## 内嵌载荷（锁定版本）

| 载荷 | 版本 | SHA-256 |
|---|---|---|
| Win32-OpenSSH x64 MSI | 10.0.0.0p2-Preview | `ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9` |
| Tailscale amd64 MSI | 1.102.3 | `03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce` |

## License

[MIT](LICENSE)
