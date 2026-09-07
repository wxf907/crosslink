; CrossLink Windows 安装包脚本 (Inno Setup 6)
; 构建：ISCC.exe crosslink_setup.iss

#define MyAppName "CrossLink 跨端互传"
#define MyAppVersion "2.3.0"
#define MyAppPublisher "CrossLink"
#define MyAppExeName "crosslink.exe"
; Release 产物目录（源码实体路径，避免联接解析回中文路径）
#define BuildDir "D:\crosslink_src\build\windows\x64\runner\Release"

[Setup]
AppId={{8E9F5C31-2B7D-4A46-9A0C-51B36D9A7E42}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
; 安装包 exe 自身也使用品牌图标
SetupIconFile=D:\crosslink_src\windows\runner\resources\app_icon.ico
DefaultDirName={autopf}\CrossLink
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; 面向当前用户安装、无需管理员权限，降低杀软误报与权限门槛
PrivilegesRequired=lowest
OutputDir=D:\crosslink_src\installer\output
OutputBaseFilename=CrossLink-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行 {#MyAppName}"; Flags: nowait postinstall skipifsilent
