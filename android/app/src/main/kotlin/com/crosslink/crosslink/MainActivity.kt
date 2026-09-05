package com.crosslink.crosslink

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.crosslink.crosslink/file_utils"
    private val FILE_PROVIDER_AUTHORITY = "com.crosslink.crosslink.fileprovider"
    private val REQUEST_SAVE_AS = 10001

    /// 公共目录下的子目录名
    private val PUB_DIR = "CrossLink"

    // SAF "另存为" 相关状态
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFolder" -> {
                        val dirPath = call.argument<String>("path")
                        if (dirPath == null) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val opened = openFolder(dirPath)
                            if (opened) {
                                result.success(true)
                            } else {
                                result.error("no_app", "No file manager app found", null)
                            }
                        } catch (e: Exception) {
                            result.error("error", e.message, null)
                        }
                    }
                    "publishToPublic" -> {
                        val srcPath = call.argument<String>("path")
                        val fileName = call.argument<String>("fileName") ?: "file"
                        val kind = call.argument<String>("kind") ?: "file"
                        val move = call.argument<Boolean>("move") ?: true
                        if (srcPath == null) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val r = publishToPublic(srcPath, fileName, kind, move)
                            if (r == null) {
                                result.error("unavailable", "无法发布到公共目录", null)
                            } else {
                                result.success(r)
                            }
                        } catch (e: Exception) {
                            result.error("error", e.message, null)
                        }
                    }
                    "saveAs" -> {
                        val srcPath = call.argument<String>("path")
                        val fileName = call.argument<String>("fileName") ?: "file"
                        if (srcPath == null) {
                            result.error("invalid_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        pendingSaveResult = result
                        pendingSaveSourcePath = srcPath
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, fileName)
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQUEST_SAVE_AS)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SAVE_AS) return
        val result = pendingSaveResult
        val srcPath = pendingSaveSourcePath
        pendingSaveResult = null
        pendingSaveSourcePath = null
        if (result == null) return
        if (resultCode != RESULT_OK || data == null || data.data == null) {
            result.error("cancelled", "User cancelled", null)
            return
        }
        val uri = data.data!!
        try {
            if (srcPath == null) {
                result.error("error", "No source path", null)
                return
            }
            val srcFile = File(srcPath)
            if (!srcFile.exists()) {
                result.error("error", "Source file not found", null)
                return
            }
            contentResolver.openOutputStream(uri)?.use { out ->
                srcFile.inputStream().use { inp ->
                    inp.copyTo(out)
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("error", e.message, null)
        }
    }

    /**
     * 把应用缓存里的文件发布到公共目录，让所有文件管理器/相册都能看到。
     *
     * 用 MediaStore 写入，Android 10+ 无需任何存储权限：
     *  - 图片 → Pictures/CrossLink（会出现在相册里）
     *  - 视频 → Movies/CrossLink
     *  - 其它 → Download/CrossLink
     * 这样"打开所在位置"在任何品牌手机上都成立，也不再需要
     * MANAGE_EXTERNAL_STORAGE（那个权限还会导致升级时系统重置已授权限）。
     *
     * 返回 {path, uri, dir}；系统不支持（Android 10 以下）或失败时返回 null。
     */
    private fun publishToPublic(
        srcPath: String,
        fileName: String,
        kind: String,
        move: Boolean
    ): Map<String, String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val src = File(srcPath)
        if (!src.exists() || src.length() <= 0) return null

        val relDir = when (kind) {
            "image" -> Environment.DIRECTORY_PICTURES
            "video" -> Environment.DIRECTORY_MOVIES
            else -> Environment.DIRECTORY_DOWNLOADS
        }
        val relativePath = "$relDir/$PUB_DIR"
        val collection = when (kind) {
            "image" -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            "video" -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }

        // 重名时自动加 (1) (2)…，与系统下载行为一致，避免覆盖
        val base = fileName.substringBeforeLast('.', fileName)
        val ext = if (fileName.contains('.')) "." + fileName.substringAfterLast('.') else ""
        var candidate = fileName
        var i = 1
        while (File(
                Environment.getExternalStoragePublicDirectory(relDir),
                "$PUB_DIR/$candidate"
            ).exists()
        ) {
            candidate = "$base ($i)$ext"
            i++
            if (i > 200) break
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, candidate)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(candidate))
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val uri = try {
            contentResolver.insert(collection, values)
        } catch (e: Exception) {
            null
        } ?: return null

        return try {
            contentResolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { inp -> inp.copyTo(out, 64 * 1024) }
            } ?: throw IllegalStateException("openOutputStream failed")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            if (move) src.delete()
            val realPath = queryDataPath(uri)
                ?: File(
                    Environment.getExternalStoragePublicDirectory(relDir),
                    "$PUB_DIR/$candidate"
                ).absolutePath
            mapOf(
                "path" to realPath,
                "uri" to uri.toString(),
                // 注意：Kotlin 中 infix `to` 优先级高于 elvis `?:`，必须加括号，
                // 否则整项被解析成 (Pair ?: "")，类型退化为 Serializable 导致编译失败
                "dir" to (File(realPath).parent ?: ""),
                "name" to candidate
            )
        } catch (e: Exception) {
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            null
        }
    }

    private fun queryDataPath(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        val idx = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                        if (idx >= 0) c.getString(idx) else null
                    } else null
                }
        } catch (_: Exception) {
            null
        }
    }

    private fun mimeOf(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "heic" -> "image/heic"
        "mp4" -> "video/mp4"
        "mov" -> "video/quicktime"
        "pdf" -> "application/pdf"
        "txt", "md" -> "text/plain"
        "doc" -> "application/msword"
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "xls" -> "application/vnd.ms-excel"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "ppt" -> "application/vnd.ms-powerpoint"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "zip" -> "application/zip"
        "apk" -> "application/vnd.android.package-archive"
        "mp3" -> "audio/mpeg"
        else -> "application/octet-stream"
    }

    /**
     * Open the system file manager and navigate to the given directory.
     *
     * Strategy (tries multiple approaches for maximum device compatibility):
     * 1. FileProvider content:// URI + ACTION_VIEW + MIME_TYPE_DIR
     *    — works on most Android 7+ devices with a real file manager app.
     * 2. DocumentsContract tree URI — fallback for devices where strategy 1
     *    is not handled (e.g. some MIUI / EMUI ROMs).
     * 3. file:// URI + resource/folder MIME — for older devices.
     * 4. ACTION_GET_CONTENT — last resort, opens any file picker.
     *
     * Returns true if an intent was successfully launched, false otherwise.
     */
    private fun openFolder(dirPath: String): Boolean {
        val dir = File(dirPath)
        // If the directory doesn't exist yet, try its parent
        if (!dir.exists()) {
            dir.parentFile?.let { parent ->
                if (parent.exists()) {
                    return openFolder(parent.absolutePath)
                }
            }
        }

        // Strategy 1: FileProvider content:// URI (Android 7+, API 24+)
        // This is the recommended modern approach — generates a content:// URI
        // that file manager apps can handle, with proper URI permission granting.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val contentUri = FileProvider.getUriForFile(
                    this,
                    FILE_PROVIDER_AUTHORITY,
                    dir
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(contentUri, DocumentsContract.Document.MIME_TYPE_DIR)
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_MULTIPLE_TASK or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                }
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Exception) {
                // Fall through to next strategy
            }
        }

        // Strategy 2: DocumentsContract tree URI
        // Works on devices where the external storage provider handles directory viewing.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val rootUri: Uri = if (dirPath.startsWith("/storage/emulated/0/Download") ||
                    dirPath.startsWith("/storage/emulated/0/Download/")) {
                    Uri.parse("content://com.android.providers.downloads.documents/tree/downloads")
                } else if (dirPath.startsWith("/storage/emulated/0/Documents") ||
                    dirPath.startsWith("/storage/emulated/0/Documents/")) {
                    Uri.parse("content://com.android.externalstorage.documents/tree/primary%3ADocuments")
                } else {
                    Uri.parse("content://com.android.externalstorage.documents/tree/primary%3A")
                }

                val relativePath = when {
                    dirPath.startsWith("/storage/emulated/0/") ->
                        dirPath.removePrefix("/storage/emulated/0/")
                    else -> ""
                }

                val docId = if (relativePath.isEmpty()) {
                    "primary:"
                } else {
                    "primary:$relativePath"
                }

                val docUri = DocumentsContract.buildDocumentUriUsingTree(
                    rootUri,
                    docId
                )

                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(docUri, DocumentsContract.Document.MIME_TYPE_DIR)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Exception) {
                // Fall through to next strategy
            }
        }

        // Strategy 3: file:// URI + resource/folder MIME (pre-N fallback)
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.fromFile(dir), "resource/folder")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {
            // Fall through
        }

        // Strategy 4: vnd.android.document/directory MIME
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.fromFile(dir), "vnd.android.document/directory")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {
            // Fall through
        }

        // Strategy 5: Last resort — open any file picker
        try {
            val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "*/*"
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {
            // All strategies failed
        }

        return false
    }
}
