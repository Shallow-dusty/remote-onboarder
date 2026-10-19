# 当前状态

## 2026-10-20 · 1.2.1-migration-cloud（源码修复，待 Windows 复验）

- 修复中文用户名连接指引：`SSH-连接信息.txt` 不再输出不可用的 `ssh -l "尚明阳"`。ASCII 用户名保留单行命令；非 ASCII 用户名改为输出控制端 `~/.ssh/config` 的 Host 段，控制端补 `IdentityFile` 后使用。
- `scripts/test-resilience.ps1` 新增 6 项断言；本机 PowerShell 7.6（macOS）解析通过，49 项健壮性断言通过。Windows PowerShell 5.1 解析、SelfTest、Windows 5.1 构建均未复跑，暂未生成新分发包。
- macOS 全自动接入包（内置 Tailscale）仍是 `build/dist` 本地产物，未纳入源码树、CI 或 Windows 构建器；无回滚脚本。

## 2026-10-10 · 1.2.0-migration-cloud（已实跑一次）

- 已部署腾讯云 Tailnet-only HTTPS 接收器，未开放公网日志服务；完整日志上传新增字节数/SHA-256 回执和私网 DNS 兼容。
- Windows 实际上传 5 个合成完整文件成功，包含中文/UTF-16/180 KB MSI 日志；Mac 独立取回两份文件核对哈希一致。上传失败保留本地测试通过。
- Python 11 项、Windows 42 项健壮性断言、Go race/vet、Windows synthetic ZIP 构建与最终配置脚本解析通过。
- 2026-10-10 20:03 朋友机器 `LAPTOP-RNN171NI`（Windows 11，中文账户尚明阳）v1.2 Cloud 包 7/7 步实际通过；Tailscale 入网、SSH 公钥登录、云端实时日志均验证。中文用户名需用 SSH config 的 `User` 字段。
- 未完成：隔离 Windows VM 全新安装、UAC、断电恢复；朋友侧 8443 权限仅该机验证。不保证 Tailnet 入网失败时也能云上传。上传预算 120 秒，单文件 32 MiB，超过明确失败，不截断；没有持久后台补传器。
- 私有部署记录与测试会话见 `build/cloud/DEPLOYMENT.md`（不属于公开发行文件）。


## 2026-10-10 · 1.1.0-migration 候选

- 用户明确选择临时迁移兼容模式：保留陌生防火墙规则并继续；默认严格模式仍保留。兼容模式只管理常规 OpenSSH 规则，不宣称全机 Tailnet-only。
- 新增 diagnostics.ps1：系统/防火墙并行批量只读采集，超时保留部分结果，安装器日志按字节限量读取；失败自动导出一个反馈 ZIP。
- MSI 1618 有界重试、服务等待、已确认同 Tailnet 的 Stopped 状态恢复、明确部分入网状态、主机指纹交付。
- 新增跨平台 ZIP/脚本更新构建器；Windows --zip 无需 IExpress/7z，EXE 模式提前检查 7z。Python 3.9 renderer 写文件兼容修复。
- 当前已通过：Python 10 项测试；Windows PowerShell 5.1 原安全 fixtures 与 42 项健壮性断言；原机实测并行诊断约 5.7 秒完成、两个任务均无错误；候选 Windows --zip 构建（固定 MSI 哈希/官方签名、生成脚本安全 SelfTest、ZIP 内容验证）通过。
- 旧 HTTPS 日志服务在本轮返回 HTTP 530 / Cloudflare 1033，未启用它，也未修改服务器；反馈 ZIP 为本次排障交付方式。
- 尚未完成：隔离 Windows 10/11 全新安装、实际 GUI/UAC、断电恢复、真实朋友端登录；不能宣称各种环境均已验收。既有不确定操作标记不会自动清除。


## 2026-10-10 · 应用包防火墙规则兼容补丁（本地未发布）

- `Get-UnsafeSshRules` 现在排除绑定具体 AppContainer Package SID 的规则：这些规则不适用于普通 Win32 sshd，即使 Program/Port 显示 Any。缺少 Package、Any 或无法识别的值仍保留原检查。
- 新增回归用例：具体 Package SID 不阻塞；Any、空值、未知值、畸形 SID 的宽规则仍阻塞。
- 已在原开发机 Windows PowerShell 5.1 运行安全 fixtures，通过；全程使用 mock 和临时文件，未修改实际服务、防火墙或账户。
- 提供仅含更新脚本/校验清单的小补丁，复用已有 ZIP 的两个 MSI 与接入配置；未重新生成 EXE，未完成朋友设备实测。
- 朋友的 CBS 规则尚未取得 Package 字段，应用包作用域是基于名称的待验证判断；不保证这一补丁解决所有阻塞。
- 该小补丁阶段未实现并行诊断；后续迁移候选的实现与边界见上节。

最后本地核查：2026-10-20。源码版本 `1.2.1-migration-cloud`；1.2.1 仅修连接信息输出，尚未生成新分发包。

## CI

`.github/workflows/ci.yml`（首个 workflow，2026-09-16 加入）在每次 push/PR 上运行：
接收器 Go vet/race 测试 + 容器构建与摄取冒烟、renderer 测试与 ShellCheck、
日志页浏览器检查、Windows PowerShell 5.1 解析与安全 fixtures、govulncheck、
gitleaks 密钥扫描。需要私密配置与固定载荷的 IExpress 打包和 `--validate-only`
自检仍在本地执行。

## 保持的产品框架

- Windows x64 单文件 IExpress 分发，PowerShell 5.1 控制台运行。
- 发送方预置公钥/短期 Tailnet 凭据，接收方双击并同意 UAC。
- Go 标准库日志接收器与内嵌原生 HTML/JS；无新数据库或前端运行时。

## 本轮改变

- 构建输入校验/转义，硬编码 SHA-256 和发布者签名检查，HTTPS 下载与日志端点。
- 保守 SSH 策略检查、其他适用 SSH 放行规则清单，已知规则之外人工处理。
- 跨工具变更 mutex、配置/key ACL/服务/规则快照，未确认操作留下 pending 标记。
- 不预删损坏 sshd 服务；MSI 路径修复不代替 capability/未知安装机制。
- 不再 reset/force-reauth 切换不同 Tailnet；SSH 会话调用被阻止。
- 本地日志脱敏、自检禁用上传，日志页搜索、暂停、手动刷新与错误保留内容。

## 已验证

- Python renderer 4 组测试、ShellCheck：通过。
- Windows PowerShell 5.1 安全 fixtures：通过；恢复仅作用于临时文件，服务和防火墙
  命令全部 mock。
- 合成配置 `--validate-only`：固定 MSI 哈希/官方签名/发布者、生成脚本解析、
  临时文件 SelfTest 通过。使用本地缓存载荷，没有真实安装。
- 接收器 Go race/vet/build：通过。
- 日志页浏览器模拟测试：空态、选中、文本转义、搜索、暂停、失败保留、360px
  窄屏通过；截图未提交。

## 行为兼容性与待验收

1. 旧 HTTP 日志端点需迁移为 HTTPS；未修改任何真实 private config 或服务器。
2. 不同 Tailnet、陌生防火墙/GPO、复杂 SSH 或不确定恢复状态会阻止运行，不能
   为了提高成功率而忽略错误。
3. 包安装、host keys、Tailnet 登录不是可逆事务。MSI 可自行启动服务/修改规则；
   安装后的配置快照不证明安装前状态可完全恢复。
4. 接收器不内置账号/认证；默认 loopback，Docker 私网部署仍需正确的网络或
   反向代理授权。HTTPS 不等于授权，不能直接公开设备日志。
5. 新版本 EXE/IExpress 分发、UAC、真实安装修复/中断恢复还需隔离目标机验收。
   未宣称线上版本已经使用本轮改动。

详见 [文档导航](docs/README.md)、[审计记录](docs/audit-2026-09.md) 和
[变更记录](CHANGELOG.md)。
