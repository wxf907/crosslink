<#
.SYNOPSIS
  CrossLink 一键发布脚本（带强制完整性门禁）。

.DESCRIPTION
  依次完成：版本一致性校验 -> 静态分析 -> 单元测试 -> 构建 EXE -> 构建 APK(仅 arm64)
  -> APK/EXE 完整性门禁 -> 复制到交付产物目录。

  任何一步失败都会立即中止并返回非零退出码，不会把半成品放进交付产物。
  （历史上 2.1.11 / 2.1.14 / 2.1.15 三个坏包正是因为缺少这道门禁流出的：
    分别丢失了 flutter_assets、两个原生库、以及整个 libapp.so。）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File D:\crosslink_src\tools\release.ps1
#>

$ErrorActionPreference = 'Stop'

$SrcRoot   = 'D:\crosslink_src'
$Junction  = 'D:\clink'                       # MSVC 不接受中文路径，构建走联接
$Delivery  = 'E:\' + [char]0x6587 + [char]0x6863 + [char]0x751F + [char]0x6210 + [char]0x6C99 + [char]0x76D2
$Delivery  = Join-Path $Delivery ([char]0x901A + [char]0x8BAF + [char]0x7A0B + [char]0x5E8F)
$Delivery  = Join-Path $Delivery ([char]0x4EA4 + [char]0x4ED8 + [char]0x4EA7 + [char]0x7269)
$Flutter   = 'D:\dev\sdk\flutter\bin\flutter.bat'
$ISCC      = 'D:\dev\InnoSetup\ISCC.exe'
$Aapt2     = 'D:\dev\android\build-tools\36.0.0\aapt2.exe'
$Keystore  = 'D:\crosslink_keystore\crosslink-release.jks'
$KeyProps  = Join-Path $SrcRoot 'android\key.properties'

# 好友二维码：仓库里只有占位图（真实码进 git 历史即永久公开），
# 正式构建前从项目外注入真图，构建结束在 finally 里还原，防误提交。
$QrRealSrc  = 'D:\crosslink_keystore\assets_private\wechat_contact_qr.png'
$QrInRepo   = Join-Path $SrcRoot 'assets\images\wechat_contact_qr.png'
$script:qrInjected = $false

# ---- 上一版已发布的最大 versionCode（防止编号倒退导致无法覆盖安装）----
$MinVersionCode = 40200

# ---- APK 必须包含的原生库（arm64）----
$RequiredLibs = @(
  'libflutter.so', 'libapp.so', 'libdartjni.so',
  'libsuper_native_extensions.so', 'libirondash_engine_context_native.so',
  'libbarhopper_v3.so', 'libdatastore_shared_counter.so',
  'libimage_processing_util_jni.so', 'libsurface_util_jni.so'
)
# ---- APK 必须包含的资源文件 ----
$RequiredAssets = @(
  'AssetManifest.bin', 'FontManifest.json', 'NOTICES.Z',
  'fonts/MaterialIcons-Regular.otf',
  'assets/images/tray_icon.ico',
  'assets/images/wechat_pay_qr.png',
  'assets/images/alipay_qr.png'
)

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "!!! $msg" -ForegroundColor Red; exit 1 }
function Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }

# 安全执行外部命令：flutter/gradle 会往 stderr 写大量正常输出，
# 在 \$ErrorActionPreference='Stop' 下会被当成异常中断脚本，故临时放宽，
# 仅以真实退出码判定成败。
function Run-Tool {
  param([string]$Exe, [string[]]$ToolArgs, [int]$Tail = 15)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @ToolArgs 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    ($out | Select-Object -Last $Tail) | ForEach-Object { Write-Host "    $_" }
    return $code
  } finally {
    $ErrorActionPreference = $prev
  }
}

# 构建前必须关闭正在运行的实例：exe 被占用会让链接器报 LNK1104，
# 表现为“构建失败”，其实只是文件锁（历史上反复踩到）。
function Stop-App {
  $procs = @(Get-Process -Name 'crosslink' -ErrorAction SilentlyContinue)
  if ($procs.Count -gt 0) {
    Write-Host ("    关闭 " + $procs.Count + " 个正在运行的 CrossLink 实例") -ForegroundColor Yellow
    $procs | Stop-Process -Force
    Start-Sleep -Seconds 2
  }
}

# APK 完整性门禁：架构唯一、原生库逐个比对、资源清单、版本号、敏感权限、体积区间。
# 必须对"最终要交付的那个文件"跑一遍，而不是只校验构建中间产物。
function Assert-ApkIntegrity {
  param([string]$ApkPath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($ApkPath)
  $entries = $zip.Entries | ForEach-Object { $_.FullName }
  $zip.Dispose()

  $abis = @($entries | Where-Object { $_ -like 'lib/*' } | ForEach-Object { ($_ -split '/')[1] } | Select-Object -Unique)
  if ($abis.Count -ne 1 -or $abis[0] -ne 'arm64-v8a') {
    Fail "APK 架构异常：$($abis -join ', ')（应只有 arm64-v8a）"
  }
  $libs = @($entries | Where-Object { $_ -like 'lib/arm64-v8a/*.so' } | ForEach-Object { Split-Path $_ -Leaf })
  $missLibs = @($RequiredLibs | Where-Object { $libs -notcontains $_ })
  if ($missLibs.Count -gt 0) { Fail "缺少原生库：$($missLibs -join ', ')" }
  Ok "原生库 $($libs.Count)/$($RequiredLibs.Count) 齐全"

  $assets = @($entries | Where-Object { $_ -like 'assets/flutter_assets/*' })
  $missAssets = @($RequiredAssets | Where-Object { $a = 'assets/flutter_assets/' + $_; -not ($assets -contains $a) })
  if ($missAssets.Count -gt 0) { Fail "缺少资源文件：$($missAssets -join ', ')" }
  $shaders = @($assets | Where-Object { $_ -like '*/shaders/*' })
  if ($shaders.Count -eq 0) { Fail '缺少编译着色器（shaders 为空）' }
  Ok "资源包 $($assets.Count) 项、着色器 $($shaders.Count) 项齐全"

  $badging = & $Aapt2 dump badging $ApkPath 2>$null | Out-String
  $mVer = [regex]::Match($badging, "versionCode='(\d+)' versionName='([^']*)'")
  if (-not $mVer.Success) { Fail '无法读取 APK 版本号' }
  # 注意：--split-per-abi 时 Flutter 会给各架构自动加 versionCode 偏移
  # （armeabi-v7a +1000、arm64-v8a +2000、x86_64 +4000），
  # 所以 arm64 包的 code = pubspec 基准值 + 2000，属正常行为而非配置错误。
  $expectedApkCode = $VerCode + 2000
  if ([int]$mVer.Groups[1].Value -ne $expectedApkCode) {
    Fail "APK versionCode=$($mVer.Groups[1].Value)，应为 $expectedApkCode（基准 $VerCode + arm64 偏移 2000）"
  }
  if ([int]$mVer.Groups[1].Value -le $MinVersionCode) {
    Fail "APK versionCode $($mVer.Groups[1].Value) 不大于线上最高 $MinVersionCode，无法覆盖安装"
  }
  if ($mVer.Groups[2].Value -ne $VerName) {
    Fail "APK versionName=$($mVer.Groups[2].Value) 与 pubspec $VerName 不符"
  }
  if ($badging -match 'MANAGE_EXTERNAL_STORAGE') {
    Fail 'APK 仍声明 MANAGE_EXTERNAL_STORAGE（该权限会导致升级重置用户权限，应已移除）'
  }
  Ok "APK 版本 $($mVer.Groups[2].Value) / code $($mVer.Groups[1].Value)，无敏感存储权限"

  $apkMb = (Get-Item $ApkPath).Length / 1MB
  if ($apkMb -lt 20 -or $apkMb -gt 32) {
    Fail "APK 体积 $([math]::Round($apkMb,1)) MB 超出合理区间 20~32MB（可能丢件或混入多余内容）"
  }
  Ok "APK $([math]::Round($apkMb,1)) MB"
}

# 串行化：禁止并发构建（并发共用 build/ 中间目录是丢件的成因之一）
$mutex = New-Object System.Threading.Mutex($false, 'CrossLink_Release_Mutex')
$owned = $false
try {
  $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  # 上次构建进程被强杀未释放锁：此时所有权已转移到本进程，可继续
  $owned = $true
}
if (-not $owned) {
  Fail '已有另一个构建在进行中，请等它结束后再运行（构建必须串行）。'
}

try {
  # ---------- 0. 环境 ----------
  Step '检查构建环境'
  foreach ($p in @($Flutter, $ISCC, $Aapt2)) {
    if (-not (Test-Path $p)) { Fail "缺少工具：$p" }
  }
  if (-not (Test-Path $KeyProps)) {
    Write-Host '    WARN 未找到 android/key.properties，APK 将回退 debug 签名（无法覆盖安装正式版）' -ForegroundColor Yellow
  } elseif (-not (Test-Path $Keystore)) {
    Fail "key.properties 指向的密钥不存在：$Keystore"
  }
  Ok '工具与密钥就绪'

  # ---------- 1. 版本一致性 ----------
  Step '校验版本号与 versionCode'
  $pubVer = (Select-String -Path (Join-Path $SrcRoot 'pubspec.yaml') -Pattern '^version:\s*([\d.]+)\+(\d+)').Matches[0]
  if (-not $pubVer) { Fail '无法解析 pubspec.yaml 的 version' }
  $VerName = $pubVer.Groups[1].Value
  $VerCode = [int]$pubVer.Groups[2].Value
  if ($VerCode -le $MinVersionCode) {
    Fail "versionCode=$VerCode 不大于线上最高 $MinVersionCode，会导致无法覆盖安装。请递增后重试。"
  }
  $issVer = (Select-String -Path (Join-Path $SrcRoot 'installer\crosslink_setup.iss') -Pattern 'MyAppVersion "([^"]+)"').Matches[0].Groups[1].Value
  $rcVer  = (Select-String -Path (Join-Path $SrcRoot 'windows\runner\Runner.rc') -Pattern 'VERSION_AS_STRING "([^"]+)"').Matches[0].Groups[1].Value
  if ($issVer -ne $VerName -or $rcVer -ne $VerName) {
    Fail "版本不一致：pubspec=$VerName iss=$issVer rc=$rcVer"
  }
  Ok "版本 $VerName (versionCode=$VerCode)，四处一致且可覆盖安装"

  # ---------- 2. 代码质量 ----------
  Step '静态分析'
  Set-Location $Junction
  $env:PATH = 'D:\dev\sdk\flutter\bin;D:\dev\git\cmd;' + $env:PATH
  $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
  $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
  if ((Run-Tool $Flutter @('analyze', '--no-pub')) -ne 0) { Fail '静态分析未通过' }
  Ok '分析零问题'

  Step '单元测试'
  if ((Run-Tool $Flutter @('test', '--no-pub') -Tail 3) -ne 0) { Fail '单元测试未通过' }
  Ok '测试全绿'

  # ---------- 2.5 注入真实好友二维码（产物用，不入库） ----------
  Step '注入真实好友二维码'
  if (Test-Path $QrRealSrc) {
    Copy-Item -LiteralPath $QrRealSrc -Destination $QrInRepo -Force
    $script:qrInjected = $true
    Ok '已注入（构建结束后自动还原为占位图）'
  } else {
    Write-Host '    WARN 未找到项目外真实码，产物联系页将显示占位图' -ForegroundColor Yellow
  }

  # ---------- 3. 构建 Windows ----------
  Step '构建 Windows EXE'
  Stop-App
  if ((Run-Tool $Flutter @('build', 'windows', '--release') -Tail 3) -ne 0) { Fail 'Windows 构建失败' }
  $WinOut = Join-Path $Junction 'build\windows\x64\runner\Release\crosslink.exe'
  if (-not (Test-Path $WinOut)) { Fail 'Windows 构建产物不存在' }
  $fileVer = (Get-Item $WinOut).VersionInfo.ProductVersion
  if ($fileVer -ne $VerName) { Fail "EXE 版本号为 $fileVer，应为 $VerName" }
  Ok "crosslink.exe $VerName"

  Step '构建 Windows 安装包'
  if ((Run-Tool $ISCC @((Join-Path $SrcRoot 'installer\crosslink_setup.iss')) -Tail 2) -ne 0) { Fail '安装包打包失败' }
  $Setup = Join-Path $SrcRoot "installer\output\CrossLink-Setup-$VerName.exe"
  if (-not (Test-Path $Setup)) { Fail "安装包未生成：$Setup" }
  Ok ("安装包 {0:N1} MB" -f ((Get-Item $Setup).Length / 1MB))

  # ---------- 4. 构建 APK（仅 arm64）----------
  Step '构建 Android APK（arm64-v8a）'
  Stop-App
  if ((Run-Tool $Flutter @('build', 'apk', '--release', '--split-per-abi') -Tail 3) -ne 0) { Fail 'APK 构建失败' }
  $Apk = Join-Path $Junction 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
  if (-not (Test-Path $Apk)) { Fail 'APK 构建产物不存在' }

  # ---------- 5. APK 完整性门禁 ----------
  Step 'APK 完整性门禁'
  Assert-ApkIntegrity $Apk

  # ---------- 6. 交付 ----------
  Step '复制到交付产物'
  if (-not (Test-Path $Delivery)) { Fail "交付目录不存在：$Delivery" }
  Copy-Item -LiteralPath $Setup -Destination (Join-Path $Delivery "CrossLink-Setup-$VerName.exe") -Force
  Copy-Item -LiteralPath $Apk   -Destination (Join-Path $Delivery "CrossLink-$VerName.apk")   -Force
  Ok "CrossLink-Setup-$VerName.exe / CrossLink-$VerName.apk"

  # ---------- 7. 交付后复检（校验对象 = 交付目录里的最终文件） ----------
  Step '交付后复检'
  $DelApk = Join-Path $Delivery "CrossLink-$VerName.apk"
  $DelSetup = Join-Path $Delivery "CrossLink-Setup-$VerName.exe"
  if ((Get-Item $DelApk).Length -ne (Get-Item $Apk).Length) { Fail '交付 APK 与构建产物大小不一致（复制损坏？）' }
  if ((Get-Item $DelSetup).Length -ne (Get-Item $Setup).Length) { Fail '交付安装包与构建产物大小不一致（复制损坏？）' }
  Assert-ApkIntegrity $DelApk
  Ok '交付文件复检通过'

  Write-Host ''
  Write-Host "===== 发布成功：$VerName (versionCode $VerCode) =====" -ForegroundColor Green
  Write-Host "交付目录：$Delivery"
}
finally {
  if ($script:qrInjected) {
    git -C $SrcRoot checkout -- assets/images/wechat_contact_qr.png 2>$null
    Write-Host '    已还原二维码占位图（真实码不入库）' -ForegroundColor Yellow
  }
  if ($owned) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
