# Academic Login 修复工作日志

日期：2026-11-26

分支：`fix/academic-login`
基线：`origin/main` (`8b2c2deee32a8197b0e0d20b040ec2c656c0e92b`)

## 本次修改

- 仅对精确教务主机 `jwzx.zjxu.edu.cn` 下 `/jwglxt/` 路径的 HTTP 导航升级到 HTTPS；保留原始 query 与 fragment，其他主机、路径和非标准端口不改写。
- 移除仅凭登录 HTML 提及“验证码”或“用户名/密码”推断失败类别的逻辑；普通表单标签和输入提示不再被归类为验证码错误。
- 增加脱敏认证诊断：登录表单识别、明确错误提示、CSRF 是否存在，以及登录页、验证码、公钥、提交和会话校验各阶段 Cookie 状态是否变化。日志不包含凭据、Cookie 值或 URL 查询参数。
- 登录页、验证码、公钥、登录提交及会话校验继续使用同一个 challenge 隔离会话；未修改 OCR 模型、寝室用电或无关认证流程。

## 验证记录

- `flutter analyze`：通过，无问题。
- 教务认证与导航定向回归：132 项通过。
- 全量 `flutter test` 默认并发运行：3,827 项通过、106 项跳过、2 项失败。Academic 入口探测用例在本机 `HTTP_PROXY` 环境下失败，清除代理变量后单独复跑通过；会话持久化用例单独复跑通过。
- 全量 `flutter test --concurrency=1`（清除代理环境变量）：3,828 项通过、106 项跳过、1 项失败（`auth_file_lock_test.dart` 的并发锁用例）；该用例单独复跑通过。全量测试因此仍不能记为完全通过。
- `git diff --check`：通过。
- `flutter build apk --release`：被项目 Release 签名门禁阻止；缺少 `KEYSTORE_FILE`、`KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD` 配置。没有改用调试签名或绕过门禁。
- OPPO PLR110 / Android 16 已连接，但未能安装 Release 包，真机 Release 验收未完成。
- 当前环境经 HTTPS 请求教务入口返回 HTTP 403（经过配置代理），没有完成真实 SSO 端到端验证。

## 未完成项

- 配置项目批准的 Release 签名后，重跑 Release APK 编译及 OPPO Android 16 真机验收。
- 获取 `JXU-diagnostics-20261126-192809689.md` 后，复核实际跳转参数和失败日志。
- 完成上述验收后再决定是否创建 PR；本日志提交本身不代表所有验收通过。

## OPPO Android 16 真机调试验收（2026-11-26）

- `flutter build apk --debug`：成功，生成 `build/app/outputs/flutter-apk/app-debug.apk`；APK SHA-256：`138F888CB88D773A3505DC75AD804C99FD579D1B9FA74FD4B451DC58A687385D`。
- OPPO PLR110 / Android 16：ADB 已连接；以 `adb install -r` 安装 `edu.zjxu.jxucampushub.dev` 成功，保留原有应用数据。此结果仅代表 Debug 包，不替代 Release 安装验收。
- 应用可启动并显示主页；进入教务系统后登录表单和验证码可见，点按刷新后验证码图像发生变化，确认验证码获取/刷新链路在该设备上可用。
- 设备原有的记住账号状态随后自动触发了一次登录尝试并显示通用失败提示。测试期间没有手动输入凭据、读取密码或再次提交；随后强制停止调试应用，未清除数据。
- 未完成真实账号认证、教务 SSO 到 `/jwglxt/` 的最终跳转、真实失败分类及 Cookie 阶段诊断验证。继续这些测试需要由用户在设备上自行完成一次登录；本次不将其标记为通过。
- Release APK 和 Release 真机验收仍受前述签名配置缺失限制。

## 对话阶段开发记录（截至 2026-11-28）

- 工作基于 `origin/main` 基线 `8b2c2deee32a8197b0e0d20b040ec2c656c0e92b`，在独立分支 `fix/academic-login` 完成并推送；分支未合并到 `main`。代码提交：`5fb22b5`；真机验收日志提交：`270b99c`。
- 已完成教务导航 HTTPS 限定升级、登录失败分类调整和脱敏诊断改进。静态分析及教务认证/导航定向测试通过；全量测试仍有并发相关用例单次失败后单独复跑通过，因此不能记为全量通过。
- Release 编译仍缺项目签名配置；当前网络环境请求教务入口曾返回 HTTP 403。两项均阻止 Release 和真实 SSO 端到端验收。
- OPPO Android 16 上只验证了 Debug `.dev` 包的安装启动、教务登录表单展示及验证码刷新。设备已有的记住账号状态触发自动登录并失败；测试未手输或记录凭据，随后停止应用且未清除数据。
- **待解决/待验证：** 真实账号认证后的服务大厅到 `/jwglxt/` HTTPS 跳转、各认证阶段 Cookie 变化及真实错误分类均未在真机验证。下一轮需避免设备保存的自动登录状态重复提交，并由账号持有人在设备本地完成认证；不应在聊天或日志中提供凭据。
- 诊断报告 `JXU-diagnostics-20261126-192809689.md` 仍未提供，相关实际跳转参数与原始失败现象未能交叉核验。全量测试、Release 编译、Release 真机验收和端到端登录未通过前，不创建 PR；本分支目前仍未创建 PR。
