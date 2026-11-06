# NeuroX

NeuroX 是面向 KSEEG102 双通道脑电设备的 Flutter 应用，提供蓝牙采集、本地信号分析、个人基线、场景任务和训练复盘。当前以 iOS 为主要产品平台，同时保留 Android 与 Web 的设备采集入口。

当前源码版本：**1.23.0+56**。版本号以 [pubspec.yaml](pubspec.yaml) 为准。

## 功能与平台范围

| 平台 | 当前入口 | 已实现范围 |
| --- | --- | --- |
| iOS | 本机账号 → 首页、设备、历史、我的 | 蓝牙采集、个人基线、学习任务、竞技／运动、专注游戏、主动恢复、历史报告与设置 |
| Android | 设备采集页 | 系统蓝牙授权、搜索连接、双通道波形、设备指标、本地还原算法及记录导出 |
| Web | 设备采集页 | Chrome Web Bluetooth、波形与指标展示、内存记录下载、显式模拟预览 |

Android 和 Web 当前没有接入 iOS 的本机账号及完整任务导航。项目尚未提供 macOS、Windows、Linux 原生桌面工程；电脑端通过 Web 运行。

### iOS 产品模块

- **本机账号**：注册、登录、多账号隔离、昵称、密码修改、退出与删除。SQLite 保存资料及记录索引，钥匙串保存密码验证凭据；没有云端账号同步。
- **设备**：蓝牙授权、扫描、连接、接收状态、双通道波形、指标及采集诊断。
- **个人基线**：采集前检查、默读适应与统计、质量判断、保存和选择当前参考。
- **学习场景**：使用任务开始时冻结的个人基线判断专注变化，记录偏离、恢复、暂停与重检事件。
- **竞技／运动**：电竞、围棋和射箭的阶段管理；按项目和阶段决定是否参与专注判断。结束比赛后可继续赛后监测，最终保存时停止任务。
- **专注训练**：跨栏、环形、六边形与视觉追踪四款游戏，分别记录游戏行为和脑电观察结果。
- **主动恢复**：示范、引导、自主练习三步流程，观察放松变化并记录主观体验。
- **历史与设置**：任务筛选、报告、分享导出、单条或批量删除，中英切换及提醒方式设置。

## 环境准备

| 用途 | 环境要求 |
| --- | --- |
| 共用开发 | Flutter SDK，所含 Dart 版本满足 `>=3.10.0 <4.0.0` |
| iOS | macOS、Xcode、iOS 15.0 或以上设备；真机安装需开发签名与设备授权 |
| Android | Android SDK、ADB、兼容当前 Flutter／Gradle 的 JDK；真机开启 USB 调试并授权 |
| Web | 支持 Web Bluetooth 的 Chrome、系统蓝牙及浏览器蓝牙权限 |
| JavaScript 测试 | 支持 `node --test` 的 Node.js |

首次获取代码后，在项目根目录执行：

```bash
flutter doctor -v
flutter pub get
flutter devices
```

原生蓝牙与本机存储通过平台代码和 Flutter Platform Channels 实现。Flutter 业务运行不依赖额外安装 Python 或厂商 Windows DLL。依赖版本由 `pubspec.yaml` 与 `pubspec.lock` 管理。

## 运行

### iOS

先用 Xcode 打开 `ios/Runner.xcworkspace`，在 Runner 的 Signing & Capabilities 中选择自己的开发团队。现有工程保留原开发团队及 Bundle ID；换开发团队时按需要调整 Bundle ID，并同步测试 target 的签名配置。

连接已授权的 iPhone，从 `flutter devices` 获取设备 ID 后执行：

```bash
# 日常点击图标独立使用，采用 Release/AOT
flutter run --release -d <设备ID>

# Flutter/Xcode 调试
flutter run --debug -d <设备ID>
```

模拟器可用于页面与交互验证；真实头带连接、接收及持续采集需在真机验证。

也可使用 [iOS 启动脚本](scripts/run-ios.sh)。该脚本保留原开发机的默认 SDK 路径和设备 ID，换电脑时应显式指定：

```bash
FLUTTER_BIN="$(command -v flutter)" ./scripts/run-ios.sh <设备ID>

# 可选调试模式
FLUTTER_BIN="$(command -v flutter)" IOS_BUILD_MODE=debug ./scripts/run-ios.sh <设备ID>
```

### Android

连接已授权的 Android 手机后执行：

```bash
flutter run -d <设备ID>
```

也可使用 [Android 启动脚本](scripts/run-android.sh)，自动选择第一台已授权设备，或传入设备 ID：

```bash
./scripts/run-android.sh
./scripts/run-android.sh <设备ID>
```

脚本通过 `ANDROID_HOME` 查找 Android SDK，未设置时使用 macOS 常见路径。换电脑时应正确设置 `ANDROID_HOME`；也可直接使用上面的 Flutter 命令。

### Web

```bash
./scripts/run-web.sh
```

用本机 Chrome 打开 **http://127.0.0.1:7357**。脚本绑定 `127.0.0.1`，默认端口为 7357，可通过 `PORT` 修改。

设备开机后，先断开其他客户端对头带的连接，再点击页面中的蓝牙设备选择入口。授权弹窗需要由用户点击触发。远程部署时需使用支持 Web Bluetooth 的安全上下文，不能直接套用本机 HTTP 地址。

网页记录暂存在内存中，应在刷新或关闭页面前停止并下载。模拟预览有明确标识，不代表头带已经连接。

## 采集与算法口径

连接成功、通知订阅完成与持续收到有效原始数据是不同状态。判断真实收数时，应同时检查页面接收状态、raw 包数和采样点是否持续更新。

移动端本地算法在独立 isolate 中执行，包括滤波、熵、FFT／频段、SDK 还原专注与放松评分等。设备发送的指标与本地计算结果分别处理。当前算法仍包含 **512 Hz 假设及临时 raw 比值配置**；这些配置不等于已经实测的硬件采样率或经过校准的物理单位。

iOS 任务先进行接收、信号质量、存储和参考兼容性检查。任务开始后冻结所用基线，历史报告读取保存时的参考与状态，不随之后更换基线重新判定。游戏行为成绩与脑电观察分别统计。

账号和记录保存在设备本地；换电脑克隆代码不会迁移手机中的资料。需要保留的业务记录应通过应用内导出功能另行保存。

## 检查与构建

在项目根目录执行以下检查：

```bash
flutter analyze
flutter test
node --test test/web_ble_transport_test.cjs
node --test test/python_ble_bridge_test.cjs
```

Python 桥接 JavaScript 测试使用模拟传输，不需要启动 Python 服务。算法测试使用仓库内 `test/fixtures/` 的参考向量。

按目标平台构建：

```bash
# Android ARM64 调试包
flutter build apk --debug --target-platform android-arm64

# Web 调试构建
flutter build web --debug --no-web-resources-cdn

# iOS Release，需在 macOS 上配置 Xcode 与签名
flutter build ios --release
```

主要产物位于 `build/app/outputs/flutter-apk/`、`build/web/` 和 `build/ios/iphoneos/`，均不纳入源码仓库。

Android Release 当前使用开发调试签名，正式分发前需单独配置发布密钥。编译、自动化测试和模拟器预览通过，分别证明对应软件检查完成，不能代替真实头带的持续采集、断连重连、后台行为及记录导出验收。

## 代码结构

| 目录／文件 | 用途 |
| --- | --- |
| [lib/main.dart](lib/main.dart) | 启动、平台入口和账号状态分流 |
| [lib/features/account/](lib/features/account/) | 本机账号与登录注册页面 |
| [lib/features/shell/](lib/features/shell/) | 四主导航、首页、历史与设置 |
| [lib/features/device/](lib/features/device/) | 设备页、接收控制和波形诊断 |
| [lib/features/tasks/](lib/features/tasks/) | 基线、任务流程、信号质量、状态判断、游戏与报告 |
| [lib/data/devices/](lib/data/devices/) | 协议解析、蓝牙传输与平台接口 |
| [lib/data/algorithms/](lib/data/algorithms/) | 本地还原算法 |
| [lib/l10n/](lib/l10n/) | 中英语言资源 |
| [ios/Runner/](ios/Runner/) | CoreBluetooth、本机存储、系统提醒和启动标记 |
| [android/app/src/main/](android/app/src/main/) | Android BLE、权限、记录与导出 |
| [web/](web/) | Web Bluetooth 与可选桥接适配 |
| [assets/](assets/) | 品牌图像与应用资源 |
| [test/](test/) | Flutter／JavaScript 测试及参考向量 |
| [scripts/](scripts/) | 启动、语言检查和其他开发辅助工具 |

## 仓库范围

[.gitignore](.gitignore) 已排除以下本地内容：

- `eegTest/`、`KSEEG102_Python_Mac/`：Python 工具和参考资料。
- `docs/`、`exports/`：产品说明、验证资料及离线文档包。
- `task_plan.md`、`findings.md`、`progress.md` 及 Planning 本地状态。
- 构建产物、依赖缓存、本机 SDK 路径、签名凭据及环境文件。

Flutter 源码、平台工程、品牌资源、测试、依赖锁文件及 Gradle wrapper 保留在仓库中。`scripts/` 内的 Python 查看器／桥接辅助工具需要上述未收录的 Python 目录，单独克隆此仓库后不能直接使用这些入口；常规 iOS、Android 与 Web Bluetooth 路径不需要它们。
