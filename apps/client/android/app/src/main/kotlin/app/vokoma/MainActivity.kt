package app.vokoma

import android.app.PendingIntent
import android.content.ClipData
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var callbackToken: String? = null
    private var pending: MethodChannel.Result? = null
    private var receiverRegistered = false
    private val handler = Handler(Looper.getMainLooper())
    private val installTimeout = Runnable {
        pending?.error("timeout", "Android installer did not report a result. Check the system installer before retrying.", null)
        pending = null
    }
    private val installResult = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { handleInstallResult(intent) }
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        if (!receiverRegistered) {
            val filter = IntentFilter("app.vokoma.INSTALL_RESULT")
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(installResult, filter, Context.RECEIVER_NOT_EXPORTED)
            else registerReceiver(installResult, filter)
            receiverRegistered = true
        }
        // Device facts and the share sheet for the engine benchmark (lib/platform/device.dart).
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.vokoma/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(mapOf(
                    "manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL,
                    "osVersion" to Build.VERSION.RELEASE, "sdk" to Build.VERSION.SDK_INT,
                    "hardware" to Build.HARDWARE, "socModel" to (if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else null),
                ))
                // A content URI to a snapshot, not the text in the Intent: the
                // log grows with every run and would exceed the Binder limit.
                // The copy also keeps a later append from changing what the
                // receiving app reads.
                "shareFile" -> try {
                    val source = File(call.argument<String>("path")!!).canonicalFile
                    require(source.path.startsWith(filesDir.parentFile!!.canonicalPath + "/")) { "Only app files can be shared" }
                    val copy = File(File(cacheDir, "share").apply { mkdirs() }, source.name)
                    source.copyTo(copy, overwrite = true)
                    val uri = FileProvider.getUriForFile(this, "$packageName.share", copy)
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                        .putExtra(Intent.EXTRA_STREAM, uri)
                        .putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject"))
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    send.clipData = ClipData.newRawUri(null, uri)
                    startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                    result.success(null)
                } catch (error: Exception) { result.error("share", error.message, null) }
                // A sleeping screen would stop rendering in the middle of a run.
                "keepScreenOn" -> {
                    if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.vokoma/updates").setMethodCallHandler { call, result ->
            if (call.method != "install") { result.notImplemented(); return@setMethodCallHandler }
            if (pending != null) { result.error("busy", "An install is already pending", null); return@setMethodCallHandler }
            try {
                val file = File(call.argument<String>("path")!!).canonicalFile
                require(file.path.startsWith(filesDir.parentFile!!.canonicalPath + "/")) { "APK must be in private app storage" }
                @Suppress("DEPRECATION")
                val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                val candidate = packageManager.getPackageArchiveInfo(file.path, flags) ?: error("Invalid APK")
                val installed = packageManager.getPackageInfo(packageName, flags)
                require(candidate.packageName == packageName) { "Package name mismatch" }
                @Suppress("DEPRECATION")
                val newer = if (Build.VERSION.SDK_INT >= 28) candidate.longVersionCode > installed.longVersionCode else candidate.versionCode > installed.versionCode
                require(newer) { "Version code must increase" }
                @Suppress("DEPRECATION")
                val incoming = (if (Build.VERSION.SDK_INT >= 28) candidate.signingInfo?.apkContentsSigners else candidate.signatures)?.map { it.toCharsString() }?.toSet()
                @Suppress("DEPRECATION")
                val existing = (if (Build.VERSION.SDK_INT >= 28) installed.signingInfo?.apkContentsSigners else installed.signatures)?.map { it.toCharsString() }?.toSet()
                require(!incoming.isNullOrEmpty() && incoming == existing) { "Signing certificate mismatch" }
                // Android performs cryptographic APK signature validation at commit as well.
                if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    result.error("approval", "Allow updates from Vokoma, then check again", null)
                    return@setMethodCallHandler
                }
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(packageName)
                if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                val installer = packageManager.packageInstaller
                val id = installer.createSession(params)
                try {
                    installer.openSession(id).use { session ->
                        session.openWrite("base.apk", 0, file.length()).use { output ->
                            file.inputStream().use { it.copyTo(output) }
                            session.fsync(output)
                        }
                        callbackToken = java.util.UUID.randomUUID().toString()
                        val intent = Intent("app.vokoma.INSTALL_RESULT").setPackage(packageName).putExtra("token", callbackToken)
                        val callback = PendingIntent.getBroadcast(this, id, intent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                        pending = result
                        handler.postDelayed(installTimeout, 4 * 60 * 1000L)
                        session.commit(callback.intentSender)
                    }
                } catch (error: Exception) { installer.abandonSession(id); pending = null; throw error }
            } catch (error: Exception) { result.error("install", error.message, null) }
        }
    }

    private fun handleInstallResult(intent: Intent) {
        if (intent.action != "app.vokoma.INSTALL_RESULT" || pending == null || intent.getStringExtra("token") != callbackToken) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            if (confirmation != null) startActivity(confirmation)
            else { pending?.error("install", "Missing install approval intent", null); pending = null }
        } else {
            if (status == PackageInstaller.STATUS_SUCCESS) pending?.success("Installed")
            else pending?.error("install", intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Install failed", null)
            pending = null
            handler.removeCallbacks(installTimeout)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(installTimeout)
        pending?.error("destroyed", "The installer activity was destroyed; check the system installer before retrying.", null)
        pending = null
        if (receiverRegistered) unregisterReceiver(installResult)
        super.onDestroy()
    }
}
