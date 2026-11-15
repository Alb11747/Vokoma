package app.vokoma

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var callbackToken: String? = null
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
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
                        val intent = Intent(this, MainActivity::class.java).setAction("app.vokoma.INSTALL_RESULT").putExtra("token", callbackToken)
                        val callback = PendingIntent.getActivity(this, id, intent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                        pending = result
                        session.commit(callback.intentSender)
                    }
                } catch (error: Exception) { installer.abandonSession(id); pending = null; throw error }
            } catch (error: Exception) { result.error("install", error.message, null) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
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
        }
    }
}
