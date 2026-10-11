# 播放缓存清理卡顿 · 实机诊断说明（临时）

> 本文件是「歌词/缓存清理卡顿」排查期的一次性说明，验证完成后连同
> `lib/services/cache_diag_logger.dart`、`test/cache_diag_logger_test.dart` 一并删除。

## 1. 日志在哪

| 文件 | 说明 |
| --- | --- |
| `%TEMP%\ka_music_cache_diag.log` | **本次运行**的全部诊断日志 |
| `%TEMP%\ka_music_cache_diag.1.log` | 上一次运行的日志（每次启动自动轮转，不会互相掺杂） |

`%TEMP%` 在文件资源管理器地址栏直接输入 `%TEMP%` 即可打开；
本次运行的完整路径也写在日志头部的 `LOGPATH=` 一行。

关闭日志：设置环境变量 `KA_MUSIC_CACHE_DIAG=0`（正常使用无需关心）。

## 2. 埋点覆盖的触发点

| 触发点 | 对应日志 `region` | 说明 |
| --- | --- | --- |
| ① 应用启动 | `init.initialize` / `load.downloadsIndex` / `load.playCacheIndex` / `prune.*` | 启动时的索引加载（逐条同步 stat）+ LRU 清理 |
| ② 一首歌首播落盘后 | `cacheForPlayback` / `audioCheck` / `persist.playCacheIndex` / `prune.*` | **最关键**：发生在切歌后 UI 恢复期间 |
| ③ 改播放缓存上限 | `ui.setPlayCacheLimit` / `prune.*` | 设置页选择 100MB~无限制 |
| ④ 手动清空 / 单首删除 | `ui.clearPlayCache` / `ui.deletePlayCache` / `clearPlayCacheDir` | 设置页「缓存管理」、「已下载」页 |
| ⑤ 打开「缓存管理」面板 | `ui.cacheManagementSheet` / `getPlayCacheDirSize` / `getDownloadDirSize` | 统计大小走同步 `listSync(recursive)+lengthSync` |
| ⑥ 正在播放（无关清理） | `fileSize` / `deleteFile` | 每一次同步文件操作的耗时 |
| ⑧ 启动索引加载细项（v2 新增） | `readIndexFile` | 拆出 定位文件 / `existsSync` / `readAsString` 三段 |
| ⑨ 数据缓存统计（v2 新增） | `getCacheSize` / `prefixStats` | 拆出 目录列举 / 逐文件 stat 两段（缓存管理面板的主开销） |
| ⑦ 掉帧 | `===== FRAME ...` | 真实帧耗时 + 丢帧数，和上面各行按 `t=` 对齐即可定位 |

### v3 新增：冷启动两个专门问题

| 现象 | region | 关键字段 |
| --- | --- | --- |
| **Windows 冷启动后立即播放：先静音 1~2 秒** | `win.play` | `PLAY_CALL`（调用 play 时的位置/电平）、`POS_FIRST_ADVANCE`（位置首次前进）、`FIRST_AUDIBLE`（**首次真正出声**，靠 `BASS_ChannelGetLevel` 判定）、`STATE`、`SNAP`（每秒快照） |
| **低端安卓冷启动 8~10 秒界面卡死** | `startup.localMusic` | `init done loadExcluded=…ms checkPermission(incl scan)=…ms`、`scan done nativeQuery=Xms parsed=N songs shown=M`（`nativeQuery` 是 Kotlin 侧 MediaStore 真实耗时） |
| 启动其他阶段 | `startup.prefsMaintenance` / `startup.firstFrame` | 首启 prefs 瘦身耗时、首帧上屏时刻 |

### v4 新增：Android 冷启动逐段量化 + 独立启动日志

**新增独立日志文件**（更容量取出，Android 免 adb）：

| 平台 | 路径 |
| --- | --- |
| Android | `/storage/emulated/0/Android/data/com.hoilai.mm.music/files/ka_startup_diag.log`（文件管理器或 USB 直接拷出） |
| Windows | `%TEMP%\ka_startup_diag.log` |

**Dart 侧逐段打点（`startup.*`）**：
`binding` / `prefsMaintenance` / `prefsBlock` / `audioServiceInit` / `theme` / `beforeRunApp` /
`firstFrameTick` / `initStateBuild` / `authRestoreCall` / `downloadsInitCall` /
`restorePlaybackCall` / `restoreQueueState` / `latestListenSongs` / `restorePlaybackState` / `localMusic`

**原生侧逐段打点（`native.*`，由 Kotlin 通过 `kgka_music_hl/diag` 回传）**：
`configureFlutterEngineStart` / `configureFlutterEngineDone` /
`createEqualizer` / `createBassBoost` / `createLoudnessEnhancer`（音频 DSP 效果首次创建耗时）

> 读法：安卓那 8~10 秒卡顿若能对上哪一段，就直接锁定。尤其看
> `native.create*`（音频效果创建）与 `startup.audioServiceInit`（前台服务注册）。

⚠️ 分析 Windows 无声问题时，`t=` 是**同一条时间轴**：
若出现 `POS_FIRST_ADVANCE` → 若干毫秒后才 `FIRST_AUDIBLE`，即证实
"源解码流位置先跑、Tempo 出声流还在预缓冲"这一病因。

## 3. 怎么读日志

```
[CACHE_DIAG] t=8123ms run=1 region=prune.total ms=6 origin=cacheForPlayback ...
===== FRAME BAD t=8150ms run=1 total=63ms build=2.1ms raster=61.0ms gap=63ms dropped~3 =====
```

- `t=` 是从本次启动起的毫秒数；**时间相邻的 CACHE_DIAG 行与 FRAME 行就是因果对**。
- `region=prune.total ms=N`：一次完整 LRU 清理耗时（扫描 + 删除）。
- `region=prune.controller` 里的 `verifySweep=...ms`：清理后**第二遍全量 stat** 的耗时。
- `===== FRAME BAD/SEVERE`：真的掉帧了。`build` 大 = Dart 侧（主 isolate 被同步 IO 阻塞）；
  `raster` 大 = GPU/合成层。**清理埋点导致的话，应该看到 build 大、且紧挨着 prune 行。**
- ⚠️ **v2 起的修正**：窗口失焦/被遮挡时 Windows 引擎会把渲染节流到约 1fps，
  由此产生 1000ms+ 的 `gap` 是假尖峰（RUN1 里 88 条 WARN 全是这个来源）。
  v2 已改为：恢复前台时重置帧基线，且 `gap >= 500ms` 不再计入 `dropped`。
  分析时请以 `total`/`build`/`raster` 为准，`gap` 仅作参考。

## 4. 建议的测试动作（v3 重点：冷启动两个问题）

**A. Windows：冷启动后立即播放（复现「先静音 1~2 秒」）**
1. 彻底退出应用（含托盘），确认无残留进程；
2. 双击启动，**尽快**点一首 30MB 以上的无损歌并播放（越早越接近冷启动）；
3. 记下「听到声音」大约是点了播放后几秒；
4. 停止播放，退出应用（日志会轮转保留）。

**B. 可选：缓存管理面板**
5. 打开设置 → 缓存管理；再把上限改小一次（触发真实删除）。

**C. 安卓：冷启动 8~10 秒卡顿（v4 重点）**

安装（保留原有数据，走覆盖安装）：
```
adb install -r dist\ka-music-startup-diag-android\ka-music-startup-diag.apk
```
若提示签名不一致，说明原包不是项目 debug 签名，只能卸载重装（会清数据）。

测试步骤：
1. 先彻底杀掉进程（最近任务里划掉）；
2. 从桌面图标冷启动，**立刻开始点界面**（切换底部 tab、点歌曲），
   感受并记下"卡到恢复"大约几秒；
3. 卡顿恢复后再正常用 30 秒（让日志落盘）；
4. 取出日志（免 adb，文件管理器或用下面的 pull 命令）：
```
adb pull /storage/emulated/0/Android/data/com.hoilai.mm.music/files/ka_startup_diag.log .
```
   或文件管理器打开：`内部存储/Android/data/com.hoilai.mm.music/files/ka_startup_diag.log`。

读法：把 `t=` 与卡顿发生的时间点对齐，看哪一段吃掉了那 8~10 秒，重点怀疑：
- `native.createEqualizer` / `createBassBoost` / `createLoudnessEnhancer`（音频 DSP 效果首次创建）
- `startup.audioServiceInit`（前台服务/通知注册）
- `startup.prefsMaintenance`（首启 prefs 瘦身）
- `startup.latestListenSongs`（恢复播放的网络请求）

完成后把日志发回（或告诉我，我直接读）。

## 4.5 Android 实测结论（2026-10-02，Philips TV / Hi3751V553 / Android 5.1.1 / armeabi-v7a）

### 已确证的事实

| 指标 | 实测 |
| --- | --- |
| 进程启动 → Dart main() | 约 564ms（引擎/linker/EGL 初始化） |
| `startup.beforeRunApp` | **175–241ms** |
| `startup.audioServiceInit` | 103–125ms |
| `startup.prefsMaintenance` | 49–101ms |
| `startup.localMusic` | 634–676ms（其中 **原生 MediaStore 查询只要 2–4ms**，`songs=0`） |
| `startup.restoreQueueState` | **904–922ms**（`queueLen=1602`） |
| `native.createEqualizer` | 6–17ms（**不是**瓶颈） |

### 真正的卡顿（Choreographer 硬证据）

```
Skipped 62 frames!  (+9.7s  from process start, ~1.03s)
Skipped 47 frames!  (+14.5s, ~0.78s)
Skipped 37 frames!  (+20.3s, ~0.62s)
```

配合 `art GC` 记录（paused 35.9ms / 10.6ms，多次）与 Dart 侧日志（t=1.18s 就已完成 runApp）可知：
**卡顿发生在首帧之后的渲染阶段，不在启动逻辑里。**

### 已排除
- 本地音乐扫描（`songs=0`，原生查询 2–4ms）
- 音频 DSP 效果创建（6–17ms）
- 前台服务注册（103–125ms）
- 首启 prefs 瘦身（49–101ms）

### v5 新增埋点（本轮定位用）
`startup.frame`：**每一帧的 build / raster 耗时 + 当前路由名**（超 24ms 才记）；
`startup.frames5s`：每 5 秒的心跳汇总（帧数 / 卡顿帧数 / 最大 build / 最大 raster）；
`startup.route`：页面切换记录。

> 读法：`raster` 高 = GPU 光栅化重（如 `BackdropFilter` 全屏模糊）；
> `build` 高 = Dart 侧构建重。当前 UI 里常驻的 `BackdropFilter(sigma=18)` 在
> `app_shell.dart`（底部导航）与 `mini_player.dart`（迷你播放器）各有一处，是首要嫌疑。
> 可用 `--dart-define=KA_DIAG_DISABLE_BLUR=true` 做 A/B 对比（`frame_diag_logger.dart` 内开关）。

## 5. 注意事项

- 日志写盘是异步 + 2 秒缓冲，本身不会造成卡顿；若怀疑，可用 `KA_MUSIC_CACHE_DIAG=0` 对比。
- 窗口最小化/后台时暂停帧采样，避免假尖峰；日志里会看到 `LIFECYCLE active=false`。
