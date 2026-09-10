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

  /// 桌面端：截图时是否先隐藏本窗口。
  /// 默认开启（截软件外部内容）；截本软件自身截图反馈问题时关闭。
  bool screenshotHideWindow;

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

  /// 桌面端：打印服务（IPP）开关
  bool printEnabled;

  /// 接入令牌（URL 路径片段，重置即换）；空=尚未生成
  String printToken;

  /// 共享的打印机名（本机已安装的打印机之一）
  String printPrinter;

  /// 每日打印页数配额（按任务份数×页数累计，防滥用）
  int printDailyPages;

  AppSettings({
    this.saveDir,
    this.notifyOnReceive = true,
    this.autoOnline = true,
    this.enterToSend = true,
    this.screenshotHotkey,
    this.screenshotHideWindow = true,
    this.backgroundOnline = true,
    this.imagePreview = true,
    this.themeColor,
    this.autoSavePublic = true,
    this.closeBehavior = 'tray',
    this.autoStart = false,
    this.printEnabled = false,
    this.printToken = '',
    this.printPrinter = '',
    this.printDailyPages = 200,
  });

  Map<String, dynamic> toJson() => {
        'saveDir': saveDir,
        'notifyOnReceive': notifyOnReceive,
        'autoOnline': autoOnline,
        'enterToSend': enterToSend,
        'screenshotHotkey': screenshotHotkey,
        'screenshotHideWindow': screenshotHideWindow,
        'backgroundOnline': backgroundOnline,
        'imagePreview': imagePreview,
        'themeColor': themeColor,
        'autoSavePublic': autoSavePublic,
        'closeBehavior': closeBehavior,
        'autoStart': autoStart,
        'printEnabled': printEnabled,
        'printToken': printToken,
        'printPrinter': printPrinter,
        'printDailyPages': printDailyPages,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        saveDir: j['saveDir'] as String?,
        notifyOnReceive: j['notifyOnReceive'] as bool? ?? true,
        autoOnline: j['autoOnline'] as bool? ?? true,
        enterToSend: j['enterToSend'] as bool? ?? true,
        screenshotHotkey: j['screenshotHotkey'] as String?,
        screenshotHideWindow: j['screenshotHideWindow'] as bool? ?? true,
        backgroundOnline: j['backgroundOnline'] as bool? ?? true,
        imagePreview: j['imagePreview'] as bool? ?? true,
        themeColor: j['themeColor'] as int?,
        autoSavePublic: j['autoSavePublic'] as bool? ?? true,
        closeBehavior: j['closeBehavior'] as String? ?? 'tray',
        autoStart: j['autoStart'] as bool? ?? false,
        printEnabled: j['printEnabled'] as bool? ?? false,
        printToken: j['printToken'] as String? ?? '',
        printPrinter: j['printPrinter'] as String? ?? '',
        printDailyPages: j['printDailyPages'] as int? ?? 200,
      );
}
