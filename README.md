# Remote-Onboarder

一次性 Windows x64 一键接入工具：把一台 Windows 机器配置好 OpenSSH、
写入控制器公钥、安装 Tailscale 并用一次性密钥加入指定 Tailnet，
全程终端实时显示进度，结构化日志实时上传到远端接收器。

面向「帮朋友配置机器」的一次性场景，刻意从简：不加密、不做多租户、
不做签名分发。健壮性优先——每一步都基于真实系统状态判断，可安全重跑。

## 交付物

构建产物只有一个文件：`SSH-Launchpad-OneClick-Windows-x64.exe`（约 35MB）。

接收方操作：

1. 双击 exe（IExpress 自解压，自动释放脚本与两个官方 MSI）
2. UAC 点「是」
3. 等终端显示完成
4. 把桌面生成的 `SSH-连接信息.txt` 发回给控制器

## 目录结构

```text
payload/                 内嵌进 SFX 的脚本（模板，未含任何密钥）
  setup.ps1              主脚本：预检/安装/配置/接入/验证/日志上传
  bootstrap.ps1          提权包装器
  launcher.cmd           SFX 入口
log-receiver/            阿里云上的实时日志接收器（Go，静态单文件 + Docker）
scripts/
  build-oneclick-windows.sh   WSL 构建脚本：下载固定版 MSI → 注入私密配置 →
                              语法/签名/自检/解包比对 → IExpress 打包 → 桌面
docs/build.md            构建流程、运行时步骤、日志与服务器部署细节
config.example.json      私密配置样例（真实配置放 build/oneclick/private-config.json，
                         0600 权限，永远不进 git）
```

## 构建（WSL）

```bash
mkdir -p build/oneclick
cat > build/oneclick/private-config.json <<'EOF'
{
  "tailscaleAuthKey": "tskey-auth-...",
  "publicKey": "ssh-ed25519 AAAA... controller"
}
EOF
chmod 600 build/oneclick/private-config.json
./scripts/build-oneclick-windows.sh
```

构建器会自动：下载并锁定两个官方 MSI（校验 Microsoft / Tailscale Authenticode
签名）、注入密钥、用 Windows PowerShell 5.1 做语法解析、跑无副作用自检
（哈希/幂等变换/ACL/日志上传链路）、IExpress 打包后不执行解包并逐文件比对，
最后放到 Windows 桌面。

## 实时日志

接收器部署在阿里云 ECS `Prism-Zero`（详见 `docs/build.md`）：

- 面板：http://203.0.113.10/ssh-launchpad-log/
- HTTPS 备用：https://log-receiver.example.com/ssh-launchpad-log/
- 数据落盘：`/opt/ssh-launchpad-log/data/*.jsonl`

日志服务器不可达时不阻塞安装，事件本地排队续传。

## 内嵌载荷（锁定版本）

| 载荷 | 版本 | SHA-256 |
|---|---|---|
| Win32-OpenSSH x64 MSI | 10.0.0.0p2-Preview | `ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9` |
| Tailscale amd64 MSI | 1.102.3 | `03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce` |
