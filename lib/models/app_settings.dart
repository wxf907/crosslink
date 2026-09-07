/// 应用设置（持久化）
class AppSettings {
  /// 文件接收保存目录（为空则使用默认专属目录）
  String? saveDir;

  /// 接收到消息/文件时是否弹窗提示
  bool notifyOnReceive;

  /// 是否开机/启动后自动上线（登录态持久化下自动登录）
  bool autoOnline;

  /// 桌面端：Enter 直接发送（Shift+Enter 换行）；关闭后 Ctrl+Enter 发送
  bool enterToSend;

  /// 桌面端：截图快捷键（hotkey_manager 的 HotKey JSON 序列化），空用默认 Alt+A
  String? screenshotHotkey;

  /// 安卓端：后台保持在线（前台服务保活），默认开启——
  /// 锁屏/切后台后系统会冻结应用导致“假在线”，保活可避免
  bool backgroundOnline;

  /// 会话内图片自动预览（关闭则显示为文件卡片样式）
  bool imagePreview;

  /// 主题色 ARGB 值（空则默认 QQ 蓝）
  int? themeColor;

  /// 安卓端：收到的文件/图片自动发布到公共目录
  /// （图片→相册 Pictures/CrossLink，其它→下载 Download/CrossLink）。
  /// 零权限，且任何文件管理器都能看到；关闭后仅留在应用缓存内。
  bool autoSavePublic;

  /// 桌面端：点窗口 × 的行为 —— 'tray' 最小化到托盘 / 'ask' 每次询问 / 'quit' 直接退出
  String closeBehavior;

  /// 桌面端：登录系统时自动启动（配合托盘常驻，保障互传/打印随时可达）
  bool autoStart;

  AppSettings({
    this.saveDir,
    this.notifyOnReceive = true,
    this.autoOnline = true,
    this.enterToSend = true,
    this.screenshotHotkey,
    this.backgroundOnline = true,
    this.imagePreview = true,
    this.themeColor,
    this.autoSavePublic = true,
    this.closeBehavior = 'tray',
    this.autoStart = false,
  });

  Map<String, dynamic> toJson() => {
        'saveDir': saveDir,
        'notifyOnReceive': notifyOnReceive,
        'autoOnline': autoOnline,
        'enterToSend': enterToSend,
        'screenshotHotkey': screenshotHotkey,
        'backgroundOnline': backgroundOnline,
        'imagePreview': imagePreview,
        'themeColor': themeColor,
        'autoSavePublic': autoSavePublic,
        'closeBehavior': closeBehavior,
        'autoStart': autoStart,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        saveDir: j['saveDir'] as String?,
        notifyOnReceive: j['notifyOnReceive'] as bool? ?? true,
        autoOnline: j['autoOnline'] as bool? ?? true,
        enterToSend: j['enterToSend'] as bool? ?? true,
        screenshotHotkey: j['screenshotHotkey'] as String?,
        backgroundOnline: j['backgroundOnline'] as bool? ?? true,
        imagePreview: j['imagePreview'] as bool? ?? true,
        themeColor: j['themeColor'] as int?,
        autoSavePublic: j['autoSavePublic'] as bool? ?? true,
        closeBehavior: j['closeBehavior'] as String? ?? 'tray',
        autoStart: j['autoStart'] as bool? ?? false,
      );
}
