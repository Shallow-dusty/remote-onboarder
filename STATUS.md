# 当前状态

最后本地核查：2026-09-13。代码内版本仍为 `1.0.0`，本轮为未发布的审计与交互
加固改动；没有构建新的可分发 EXE，也没有覆盖桌面已有版本或修改线上日志服务。

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
