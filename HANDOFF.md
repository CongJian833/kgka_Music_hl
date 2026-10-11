# 交接文档（TV 遥控器适配 + 前序排查历史）

> 本文档用于把当前对话窗口的上下文完整移交给下一个窗口。
> 生成时间：2026-10-02 晚。最后状态：`flutter analyze --no-pub lib` **全绿**。

---

## 0. 一句话现状

正在做 **KA Music（Flutter）的 Android TV 遥控器适配**。P1（焦点基础设施）+ P2（全局遥控键）
+ P4（播放器页：歌词可聚焦、进度条 ±5 秒）**已完成并通过静态检查**；
P3（各页面可聚焦化）已完成主要卡片与页面作用域；**尚未完成一次真机遥控器验证**（构建/安装在收尾时被打断）。

---

## 1. 项目与构建环境（必须照抄，否则构建失败）

| 项 | 值 |
| --- | --- |
| 工程根目录 | `E:\workspace-music` |
| Flutter SDK | `E:\flutter-sdk`（**不在 PATH 里**，每次要手动加） |
| JDK（Gradle 必需） | `E:\workspace-music\jdk17-tmp\jdk-17.0.20.1+1`（系统默认是 Java 25，Gradle 会失败） |
| Android SDK | `E:\Android_SDK`（`android/local.properties` 里也写了 `sdk.dir=E:\Android_SDK`） |
| adb | `E:\Android_SDK\platform-tools\adb.exe` |
| 测试设备 | Android TV/盒子：`Philips 8H94A_MG7294` / Hi3751V553 / **Android 5.1.1 (API 22)** / armeabi-v7a / 1GB RAM |
| 设备连接 | `adb connect 192.168.10.5:5555`（无线；user 说可能密码 `adb36987`，实际没用到） |
| 包名 | `com.hoilai.mm.music` |

**标准构建命令模板（PowerShell）**：

```powershell
cd E:\workspace-music
$env:PATH = 'E:\workspace-music\jdk17-tmp\jdk-17.0.20.1+1\bin;E:\flutter-sdk\bin;' + $env:PATH
$env:JAVA_HOME = 'E:\workspace-music\jdk17-tmp\jdk-17.0.20.1+1'
$env:ANDROID_HOME = 'E:\Android_SDK'
$env:ANDROID_SDK_ROOT = 'E:\Android_SDK'

# 静态检查
flutter analyze --no-pub lib

# 安卓 release（正式）
flutter build apk --release --target-platform android-arm,android-arm64

# 安卓 profile（要 logcat 观测时用；debugPrint 在 release 会被剥离）
flutter build apk --profile --target-platform android-arm,android-arm64

# 安装（见"注意事项"里的坑）
& 'E:\Android_SDK\platform-tools\adb.exe' install -r build\app\outputs\flutter-apk\app-release.apk
```

Windows 桌面包：`flutter build windows --release`，产物 `build\windows\x64\runner\Release\`。

---

## 2. 用户诉求（按时间顺序）

1. **歌曲缓存自动清理时机** + 降低清理卡顿 → 已排查完（结论：清理本身不慢，见 §6）。
2. **Windows 冷启动后立即播放会先无声 1~2 秒** → 怀疑已定位（见 §6），用户已表示"算了不折腾"。
3. **低端安卓设备冷启动有 8~10 秒界面卡顿期** → 用户"好想修"，见 §7 的完整结论与未完成项。
4. **"原版歌词"在低端设备上高亮异常**（只在每行开头高亮一点，暂停才跳到正确位置）
   → 已定位根因并修了一处，**但用户反馈仍未修好**；最终用户决定用「轻量歌词」绕过（设置里已有开关）。
5. **【当前任务】适配 Android TV 遥控器**，按安卓 TV 标准：
   - 主页、设置等页面：**从上到下、从左到右**顺序选中；
   - 播放器页**单独适配**：**歌词只有当前行可被聚焦**，此时确定键 = 屏幕单击；
     **进度条左键倒退 5 秒、右键前进 5 秒**；
   - 其它我自行合理安排。

---

## 3. 当前任务（TV 遥控器）已完成的部分

### 3.1 新增文件（全部是本轮新建）

| 文件 | 作用 |
| --- | --- |
| `lib/ui/widgets/tv_focus.dart` | **核心**：`TvFocusMode`（开关/参数）、`TvFocusHighlight`（焦点高亮：边框+外发光+轻微放大）、`TvFocusable`（自管确定键=onTap）、`TvFocusTarget`（只给子树加焦点，点击仍由子树处理）、`tvFocusTarget()`、`TvFocusScope`（页面级：初始焦点 + 返回记忆） |
| `lib/ui/widgets/tv_navigation_scope.dart` | 根级遥控键作用域：媒体键（播放/暂停/上一首/下一首）映射到 PlayerController |
| `lib/ui/widgets/tv_nav_bar.dart` | 遥控器友好的底部导航（`TvBottomNavBar` / `TvNavDestination`），因为标准 `BottomNavigationBar` 的 item 不能被 D-pad 稳定聚焦 |
| `android/app/src/main/res/drawable/tv_banner.png` | TV banner（320×180，脚本生成，`dist/make_banner.py`） |

### 3.2 改动文件

- `lib/main.dart`：`TvFocusMode.enabled = Platform.isAndroid`（桌面端关，避免鼠标点击出焦点框）；
  `debugLogFocus = true`（**诊断用，交接后可按需关闭**）；`MaterialApp.builder` 外包 `TvNavigationScope`。
- `android/app/src/main/AndroidManifest.xml`：
  - 加 `LEANBACK_LAUNCHER` intent-filter；
  - `<uses-feature touchscreen required=false>`、`software.leanback required=false`；
  - `android:banner="@drawable/tv_banner"`。
- **卡片可聚焦化**（用 `TvFocusTarget` 包 build，内部改名 `_buildXxxInner`）：
  - `home_page.dart`：`_FeatureCard`、`_PlaylistCard`、`_RadioHeroCard`、`_RadioStationCard`、`_PillCard`、`_TopSongCard`、`_TopAlbumCard`
  - `library_page.dart`：`_QuickActionCard`、`_PlaylistRow`、`_TabItem`、`_SortOptionTile`
  - `playlist_detail_page.dart`：`_SongRow`、`_SimilarPlaylistCard`、`_SortOptionTile`
  - `artist_detail_page.dart`：`_ArtistAlbumCard`、`_ArtistSongRow`
  - `playback_history_page.dart`：`_HistorySongRow`；`album_shop_page.dart`：`_AlbumCard`；`cloud_drive_page.dart`：`_CloudSongRow`
  - `settings_page.dart`：`_SettingsTile`
- **页面级 `TvFocusScope`**（初始焦点 + 记忆）：home / library / settings / playlist_detail / artist_detail /
  playback_history / album_shop / cloud_drive / downloaded_songs / search。
- **播放器页 `player_page.dart`**：
  - 新增 `TvLyricFocus` 组件，包住 `_LandscapeLyricPanel`（站点：`Expanded(child: TvLyricFocus(...))`）。
    确定键 → `player.seek(当前行开始时间)`，与"单击当前歌词行"一致（含歌词偏移 `_probe`）。
  - `_ProgressState.build` 被包了一层 `Shortcuts`：**左键 = -5s，右键 = +5s**（`_TvSeekBackIntent` / `_TvSeekForwardIntent`）。
- `lib/ui/widgets/tv_focus.dart` 里 `TvFocusScope` 用 **`WidgetOrderTraversalPolicy`（几何遍历）**——
  这是 TV 的关键点：不能用 `ReadingOrderTraversalPolicy`（会按构建顺序跳）。

### 3.3 尚未完成（下一个窗口接着做）

1. **底部导航替换未落地**：`tv_nav_bar.dart` 已写好，但 `app_shell.dart` 里的替换**失败**（字符串锚点在 CRLF 文件上没匹配上，`anchor found: false`）。仍在使用标准 `BottomNavigationBar`（第 295 行附近）。
2. **真机遥控器验证未做**：**这是最重要的一步**。建议：
   - 构建 **profile** 包（release 会剥离 debugPrint），安装后启动，用
     `adb shell input keyevent KEYCODE_DPAD_DOWN/RIGHT/UP/LEFT/KEYCODE_DPAD_CENTER` 注入按键；
   - `adb logcat | Select-String TV_FOCUS` 观察 `[TV_FOCUS] target ... focused=true/false` 是否按预期移动；
   - 校验顺序是否符合"上→下、左→右"。
3. **未覆盖的可聚焦点**：`_HomeSongRow`（首页歌曲行）、`_DownloadedSongRow`、`_FailedRow`、
   `_SettingsSwitchTile`、`_CacheItem`、`_ActionOptionTile`、`_AccountRow`、弹窗/底部弹窗
  （`showModalBottomSheet` / `AlertDialog` 里的按钮）、`mini_player.dart`、`song_action_sheets.dart`、
   车机顶部导航 `_buildCarTopNavBar`。
4. **可选打磨**：设置页里加"TV 模式/焦点高亮"开关；播放器页歌词聚焦时的视觉反馈细化；
   长按/重复键（`KeyRepeatEvent`）的连续 seek。

### 3.4 继续施工的关键技术约定（务必遵守）

- **不要**用 `pwsh` 的 `Get-Content/Set-Content` 改源码（会按 ANSI 解码破坏中文，见 §8 事故）。
  一律用 write/edit 工具，或 Node 脚本 + `fs.writeFileSync(..., 'utf8')`。
- **改 build 方法时**：用"类名 → 找 `  Widget build(BuildContext context) {` → **大括号计数**找结束"
  的方式，**不要**用 `indexOf('\n  }\n')` 或正则跨行匹配——文件混用 CRLF/LF，已因此删坏过文件。
- 文件混用换行：`home_page.dart`/`player_page.dart` 等是 **CRLF**；比对字符串时注意。
- `TvFocusMode.enabled` 只在 Android 为 true；桌面端调试 TV 行为时需手动置 true。
- 焦点日志：`TvFocusMode.debugLogFocus`（当前 `main.dart` 里写死 true）。

---

## 4. 前序排查结论（避免重复劳动）

### 4.1 缓存清理（已结案）
- 触发点 3 处：**冷启动 / 每首歌首播缓存落盘后 / 用户改上限**；无自动定时清理。
- 实测清理本身**很快**（`prune.total` 0~12ms，删 13 个文件 14ms），**不是卡顿源**。
- 真正开销在**打开「缓存管理」面板**：`getCacheSize` 平均 54ms、`prefixStats` 56ms（目录枚举 280+ 个文件）。
- 详细数据：`dist/ANDROID_TV_FINDINGS.md`、`dist/run1-log/`。

### 4.2 安卓冷启动卡顿（未完全解决）
实测（TV）：`beforeRunApp` 175~284ms、`audioServiceInit` 61~158ms、`localMusic` 原 956ms（**已优化到 34~40ms**；
改为"进本地音乐页/我的页时才扫描"）、`restoreQueueParse` **仅 100ms**（jsonDecode 89 + fromCache 11）。

- **主线程阻塞实测 32 次 / 合计 9.1 秒**（单次最大 2601ms），"阻塞归因路标"停在
  `home:loadBegin → home:cacheWriteBegin` 与 `prepareRestoredSong → loadClimax` 之间。
- 最大单帧 `build=2245~2441ms, raster=6.5ms` → **UI 线程构建**，发生在首页数据到位后的重建 / 进播放器页时。
- **持续不跟手（播放器/歌词页）**：`raster=50~60ms/帧`（~16fps），build 只有 3~25ms → **瓶颈是 GPU 光栅化**
  （全屏模糊 + 歌词绘制）。**用户已决定用「轻量歌词」设置绕过**。
- 已失败/放弃的手段：VM Service `getCpuProfile` 返回 0 样本；`ext.flutter.profileWidgetBuilds` 只返回开关；
  `getVMTimeline` 只有 metadata 事件（无 duration）；在 App 内插 `Stopwatch` 计量因**阈值 40ms**而被过滤
  （已把 `MainThreadLagMonitor.record` 阈值降到 **4ms**，但是否真机验证过不确定）。
- **方案 A（队列解析移 isolate）已被实测推翻并撤回**：队列解析只占 100ms，不值得改。

### 4.3 歌词高亮（用户侧未修好）
- 根因：**位置流到达间隔 2.3~9.6 秒**，`position` 长时间不更新，而 `smoothPosition = position + clock.elapsed`
  只在位置流到达时重建基线 → 逐字高亮几乎不前进；暂停时 `smoothPosition` 走 `!isPlaying ? position` 分支，
  读数立刻正确（解释"暂停后才跳对"）。
- 已加 `PlayerController.refreshPositionFromHandler()`（歌词 ticker 每 16ms 主动刷新基线），
  实测位置值开始连续前进，**但用户反馈观感仍异常**。最终决定用「轻量歌词」绕过。

---

## 5. 已保留 / 已撤回的改动清单

**保留（有实测收益）**
1. `prefs_maintenance.dart`：新增 `ka_music_prefs_purged_v1` 标记，prefs 瘦身只做一次（201ms → 56~86ms）。
2. `local_music_controller.dart` + 相关页面：本地音乐扫描改**惰性**（956ms → 34~40ms）。
3. `bass_engine.dart`：BASS FFI 绑定改**惰性加载**——原先顶层 `DynamicLibrary.open('bass.dll')` 会被打进安卓包，**安卓一启动就崩**。
4. `player_controller.dart`：`refreshPositionFromHandler()`（歌词位置基线刷新）。
5. 诊断设施：`cache_diag_logger.dart`、`startup_diag_logger.dart`、`frame_diag_logger.dart`、
   `main_thread_lag_monitor.dart`（主线程阻塞全景 + 归因路标 `crumb()`）。
6. TV 适配（本轮，见 §3）。

**已撤回**
- 恢复播放延迟到首帧之后启动（A/B 无净收益、改变播放时序）。
- 队列解析移 isolate（实测只省 ~100ms）。

---

## 6. 关键文件与日志位置

| 内容 | 路径 |
| --- | --- |
| 安卓侧诊断日志（设备上） | `/storage/emulated/0/Android/data/com.hoilai.mm.music/files/ka_startup_diag.log` |
| 同上（Windows） | `%TEMP%\ka_startup_diag.log` |
| 缓存清理日志 | `%TEMP%\ka_music_cache_diag.log` |
| 前几轮完整结论 | `dist/ANDROID_TV_FINDINGS.md` |
| 事故与恢复记录 | `dist/RECOVERY_NOTE.md` |
| 拉取设备日志 | `adb pull /storage/emulated/0/Android/data/com.hoilai.mm.music/files/ka_startup_diag.log .` |
| 诊断说明（埋点清单/测试步骤） | `CACHE_DIAG.md`（仓库根） |
| 本轮 TV 相关新文件 | `lib/ui/widgets/tv_focus.dart`、`tv_navigation_scope.dart`、`tv_nav_bar.dart` |

---

## 7. 踩过的坑（务必避免重犯）

1. **不要用 pwsh 改写源码**：`(Get-Content -Raw) -replace ... | Set-Content` 会用 ANSI(GBK) 解码 UTF-8，
   把中文变乱码并吃掉换行。**已发生两次事故**。
2. **恢复被覆盖的未提交文件**：可用 Flutter 构建快照 `.dart_tool/flutter_build/<hash>/app.dill`——
   里面存有**每个库的源码字符串**。方法：`Buffer.indexOf("file:///E:/workspace-music/lib/.../文件.dart")`，
   其后第一个 `import '` 即源码起点，往后**逐字节扫描直到出现不可打印字节**（长度前缀不可靠、源码可能分片）。
   已用此法完整恢复过 `music_audio_handler.dart`（617 行）与 `home_page.dart`（2678 行）。
   **恢复后必须 `flutter analyze` 校验**。
3. **不要用 `git checkout HEAD -- <file>` 覆盖工作区**：本项目**大量改动未提交**，会直接丢代码。
   先 `git status --porcelain` / `git diff --stat` 确认。
4. **连续多次 `adb install -r` 会让包管理器卡死**：报 `INSTALL_FAILED_INTERNAL_ERROR` +
   logcat `Failed to bind to media container service`。**解法：重启设备**（`adb reboot`）后即可正常安装。
5. **profile 构建 ≠ release 表现**：profile 下 `platformSetSource` 会放大到 17 秒（release 2~9.5 秒），
   不要用 profile 数据下 release 结论；`debugPrint` 在 release 会被剥离。
6. `adb shell` 的老设备命令缺失：`pidof`/`grep`/`head`/`wc` 都可能没有；`run-as` 对 release 包不可用。
7. 设备 RAM 只有 **1GB**（`MemTotal: 1005896 kB`），GC 压力大（实测 `art GC paused 35.9ms`）。

---

## 8. 建议的下一步执行顺序

1. **先把底部导航替换落地**（`app_shell.dart` 第 295 行附近，用 `TvBottomNavBar` 替换 `BottomNavigationBar`），
   然后在电视上跑一次遥控器验证。验证方法见 §3.3.2。
2. 按 §3.3.3 补齐剩余可聚焦点（尤其**弹窗/底部弹窗**，TV 上没有它们会"退不出来也点不动"）。
3. 真机验证通过后，把 `TvFocusMode.debugLogFocus` 改回 false（或按 dart-define 控制），
   并构建最终 release 包。
4. （可选）把 TV 适配的说明追加到 `update.md` / `CACHE_DIAG.md`，并清理诊断埋点。

> 诊断埋点（`startup_diag_logger` / `frame_diag_logger` / `main_thread_lag_monitor` / `CacheDiagLogger`）
> 目前仍留在代码里，**正式发版前需要决定去留**（建议保留 `main_thread_lag_monitor`，其余按需移除）。


---

## 9. 交接瞬间的精确状态（2026-10-02 20:0x）

- `flutter analyze --no-pub lib` → **No issues found**。
- 已构建产物：
  - `build/app/outputs/flutter-apk/app-release.apk`（20:02，含 TV 适配）
  - `build/app/outputs/flutter-apk/app-profile.apk`（20:05，含 TV 适配 + 焦点日志）
- **设备已离线**：交接时 `adb connect 192.168.10.5:5555` 超时（电视可能休眠/重启）。
  下一次开始前先 `adb connect 192.168.10.5:5555`（必要时唤醒电视），并用
  `adb shell dumpsys package com.hoilai.mm.music | Select-String lastUpdateTime` 确认装的是哪一版。
- **最后一次操作被打断**：我做完"开启 `TvFocusMode.debugLogFocus` 并重新构建 profile"后，
  正准备安装并注入 D-pad 按键验证，用户要求交接。因此
  **"遥控器导航是否真机生效"尚未验证**——这是下一窗口的第一优先级（方法见 §3.3.2）。
- 未落地的改动只剩一处：`app_shell.dart` 里 `BottomNavigationBar` → `TvBottomNavBar` 的替换（§3.3.1）。
- 建议接手第一步：
  1. `cd E:\workspace-music` 并按 §1 设置 4 个环境变量；
  2. `flutter analyze --no-pub lib` 确认无回归；
  3. 完成 `app_shell.dart` 的导航替换；
  4. `flutter build apk --profile ...` → 安装 → 注入方向键 → 查 `TV_FOCUS` 日志验证。
