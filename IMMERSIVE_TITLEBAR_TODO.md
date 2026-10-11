# 沉浸式窗口 · 自绘顶栏 + 窗口按钮 —— 任务进度保存

> 目的：压缩上下文后，可据此直接继续，无需重新探索。

## 任务目标
Windows 平台让顶部系统标题栏"融入"主窗口：隐藏系统标题栏，用 Flutter 自绘顶栏承载右上角 最小化/最大化/关闭 三按钮 + 可拖拽移动，并在各页面顶部为窗口按钮让位（避免重叠）。

## 入口 / 关键文件
- 窗口初始化：`lib/services/desktop_controller.dart`（`attach()`，已加 `setTitleBarStyle(TitleBarStyle.hidden)`）
- 自绘顶栏组件：`lib/ui/widgets/window_title_bar.dart`（新增）
- 挂载点：`lib/main.dart` 的 `MaterialApp.builder`（约 L207-228），Windows 用 `Stack`：页面内容 `Positioned.fill` 贴顶铺满 + `WindowTitleBar` 置于最上层覆盖（透明）。
- 其它页顶部让位：`lib/ui/pages/player_page.dart` 等
- Windows runner（原生方案用）：`windows/runner/main.cpp`、`win32_window.[h|cpp]`、`flutter_window.[h|cpp]`

## 已完成（含本轮）
1. **隐藏系统标题栏**：`desktop_controller.attach` 内 `windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility:true)`。
2. **自绘顶栏** `WindowTitleBar`（`window_title_bar.dart`）：
   - `Stack`：顶部可拖拽条 = `Positioned(top:0,left:0,right:controlAreaRight,height:height, child: DragToMoveArea(...))`（右端让出按钮区，避免拖拽抢到按钮手势）；
   - 右上角三按钮 `Positioned(top:0,right:0)`：最小化(`windowManager.minimize()`) / 最大化(还原, `maximize/restore`, 图标随状态) / 关闭(`windowManager.close()`，走现有收托盘/退出逻辑);
   - 按钮透明、悬停高亮、关闭悬停变红；`_TitleBarButton` 组件；`_MaximizeButton`。
   - 常量 `static const double controlAreaRight = 46*3; // 138` 供各页面顶部让位。
3. **最大化/还原图标同步 = 原生 WM_SIZE→MethodChannel（本轮完成）**：
   - `windows/runner/flutter_window.[h|cpp]`：新增 `window_state_channel_`（`ka_music/window_state`，`StandardMethodCodec`）；在 `FlutterWindow::MessageHandler` 内、`HandleTopLevelWindowProc` 之前拦截 `WM_SIZE` 并 `InvokeMethod("windowStateChanged")`（避免被插件吞掉；是否最大化交给 Dart 权威判断，规避 frameless 全屏下 `IsZoomed()` 可能 false 的问题）。
   - `window_title_bar.dart`：`_MaximizeButtonState` 监听该 channel，收到即 `windowManager.isMaximized()` 刷新；**已移除原 400ms 轮询 Timer**。
4. **各页面顶部为窗口按钮让位**（`right: Platform.isWindows ? WindowTitleBar.controlAreaRight : 0`）：
   - 播放器竖屏/横屏顶栏（`player_page.dart`，已完成）；
   - 本轮：home 顶部 `_TopTabs`、library header Row、search（普通 AppBar 取消/车机搜索头）、local_songs、playlist_detail、playback_history 的 `actions`/Row 外层已让位；settings(纯标题)、cloud_drive、downloaded_songs 右侧无交互控件，判定无需让位。

## 注意（历史环境遗留）
- 覆盖安装时若已装目录的 `kgka_music_hl.exe` 被旧实例锁定会报 Inno 退出码 5，重试即可（本轮首装 exit 5，重试 exit 0 成功）。本环境存在若干无法由当前会话中止的历史残留进程，不影响新安装产物落位。

## 出包验证流程（自动，无需追问）
```
flutter build windows --release
E:/InnoSetup/ISCC.exe installer/kgka_music_hl.iss
Start-Process <安装包> -ArgumentList /VERYSILENT,...,-Wait    # 静默安装
校验安装包修改时间：E:\workspace-music\installer\Output\KA-Music-Setup-2.6.0.exe
安装后位于：C:\Users\Administrator\AppData\Local\Programs\KA Music\kgka_music_hl.exe
```
flutter 路径：`E:\flutter-sdk\bin\flutter.bat`（系统 PATH 无 flutter）。
应用名：KA Music；退出已处理干净（`_quit` 末尾 `exit(0)` 兜底）。

## 项目硬约束（勿破坏）
- Flutter 3.32.8 / Dart ^3.8.0；Android compileSdk 36、NDK 28.2.13676358；权限 permission_handler_android ^13.0.1。
- Windows：KA Music 名、托盘 tray_manager、window_manager；收托盘后 `setUIVisible(false)` 停 Ticker。
- 歌词触摸/双模糊等历史改动均已完成并验证，勿动。