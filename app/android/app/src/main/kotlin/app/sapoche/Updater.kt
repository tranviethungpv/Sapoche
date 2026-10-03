package app.sapoche

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import android.provider.Settings
import app.sapoche.core.Release
import app.sapoche.core.UpdateClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.security.MessageDigest

/** Where an update stands; the UI shows it in Settings and as a dot on the gear. */
data class UpdateState(
    val phase: Phase = Phase.IDLE,
    val installed: String = "",
    val release: Release? = null,
    val doneBytes: Long = 0,
    /** Why the last step failed: a short code the UI turns into words. */
    val error: String? = null,
) {
    enum class Phase { IDLE, CHECKING, UP_TO_DATE, AVAILABLE, DOWNLOADING, READY, NEEDS_PERMISSION, INSTALLING, FAILED }
}

/**
 * The app updating itself from the server's private bucket. It only works when somebody looks: a check
 * when the screen opens (at most every [CHECK_EVERY_MS]), nothing in the background, so it costs no battery.
 * The file is checked against the size and checksum the server announced, and against this app's own
 * signing certificate, before it is handed to the system installer.
 */
class Updater(
    private val context: Context,
    private val client: UpdateClient,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val prefs = context.getSharedPreferences("sapoche", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val dir = File(context.cacheDir, "update")
    private var job: Job? = null

    private val installedCode: Long
    private val installedName: String

    init {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        installedCode = info.longVersionCode
        installedName = info.versionName.orEmpty()
        // What an earlier update left behind is of no use once that version (or a later one) is installed
        dir.listFiles()?.forEach { file ->
            val code = Regex("app-(\\d+)\\.apk").find(file.name)?.groupValues?.get(1)?.toLongOrNull()
            if (code == null || code <= installedCode) file.delete()
        }
    }

    private val flow = MutableStateFlow(UpdateState(installed = installedName))
    val state: StateFlow<UpdateState> get() = flow

    private fun part(release: Release) = File(dir, "app-${release.versionCode}.apk.part")

    private fun isMetered() = context.getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered != false

    /**
     * Asks the server what is newest. Without [force] it does nothing if it asked a short while ago, and
     * a failure stays quiet; with it (the person pressed "Check") the failure is shown. When there is a
     * newer release and the phone is on an unmetered network the file is fetched right away.
     */
    fun check(force: Boolean) {
        if (job?.isActive == true) return
        val last = prefs.getLong(KEY_CHECKED, 0)
        if (!force && now() - last in 0 until CHECK_EVERY_MS) {
            // Asked recently; a release found then is still on offer
            if (flow.value.phase == UpdateState.Phase.IDLE) restore()
            return
        }
        job = scope.launch {
            val before = flow.value
            flow.value = before.copy(phase = UpdateState.Phase.CHECKING, error = null)
            try {
                val release = client.latest()
                prefs.edit().putLong(KEY_CHECKED, now()).apply()
                if (release == null || !release.isNewerThan(installedCode)) {
                    flow.value = flow.value.copy(phase = UpdateState.Phase.UP_TO_DATE, release = null)
                    return@launch
                }
                saveRelease(release)
                flow.value = flow.value.copy(phase = UpdateState.Phase.AVAILABLE, release = release, doneBytes = 0)
                if (!isMetered() && !SapocheApp.heat.calm.value) fetch(release)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                EventLog.d("update", "check failed: ${e.javaClass.simpleName}: ${e.message}")
                // A quiet check leaves the screen as it was; one the person asked for says what happened
                flow.value = if (force) before.copy(phase = UpdateState.Phase.FAILED, error = "unreachable") else before
            }
        }
    }

    /** After a restart a release found earlier is still offered, without asking the server again. */
    private fun restore() {
        val release = loadRelease() ?: return
        if (!release.isNewerThan(installedCode)) return
        val ready = part(release).let { it.exists() && it.length() == release.size }
        flow.value = flow.value.copy(phase = if (ready) UpdateState.Phase.READY else UpdateState.Phase.AVAILABLE, release = release)
    }

    /** Fetches the offered release; false when it is waiting for the person to allow mobile data. */
    fun download(allowMetered: Boolean): Boolean {
        val release = flow.value.release ?: return true
        if (job?.isActive == true) return true
        if (isMetered() && !allowMetered) return false
        job = scope.launch { fetch(release) }
        return true
    }

    private suspend fun fetch(release: Release) {
        flow.value = flow.value.copy(phase = UpdateState.Phase.DOWNLOADING, release = release, doneBytes = part(release).length(), error = null)
        try {
            client.download(release, part(release)) { done -> flow.value = flow.value.copy(doneBytes = done) }
            flow.value = flow.value.copy(phase = UpdateState.Phase.READY)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            EventLog.d("update", "download failed: ${e.javaClass.simpleName}: ${e.message}")
            flow.value = flow.value.copy(phase = UpdateState.Phase.FAILED, error = "download")
        }
    }

    /** The person may have allowed installs on the system page and come back: the file is ready to install again. */
    fun refreshPermission() {
        if (flow.value.phase == UpdateState.Phase.NEEDS_PERMISSION && context.packageManager.canRequestPackageInstalls()) {
            flow.value = flow.value.copy(phase = UpdateState.Phase.READY)
        }
    }

    /** Opens the system page where the person lets this app install other apps; it has to be done once. */
    fun openInstallSettings() {
        context.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, android.net.Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    /**
     * Hands the downloaded file to the system installer. The app is stopped and started again by the system when
     * it succeeds. False when Android first has to be told to allow this app to install: the UI explains that.
     */
    fun install(): Boolean {
        val state = flow.value
        val release = state.release ?: return true
        val file = part(release)
        EventLog.d("update", "install asked: ${release.versionName}, may install: ${context.packageManager.canRequestPackageInstalls()}")
        if (!context.packageManager.canRequestPackageInstalls()) {
            flow.value = state.copy(phase = UpdateState.Phase.NEEDS_PERMISSION)
            return false
        }
        val problem = problemWith(file, release)
        if (problem != null) {
            EventLog.d("update", "file refused: $problem")
            file.delete()
            flow.value = state.copy(phase = UpdateState.Phase.FAILED, error = problem)
            return true
        }
        EventLog.d("update", "handing ${file.length()} bytes to the system installer")
        flow.value = state.copy(phase = UpdateState.Phase.INSTALLING, error = null)
        job = scope.launch {
            try {
                commit(file)
            } catch (e: Exception) {
                EventLog.d("update", "install failed: ${e.javaClass.simpleName}: ${e.message}")
                flow.value = flow.value.copy(phase = UpdateState.Phase.FAILED, error = "install")
            }
        }
        return true
    }

    /** Why the file must not be installed, or null. The system would refuse a foreign file too, but later and less clearly. */
    private fun problemWith(file: File, release: Release): String? {
        if (!file.exists() || file.length() != release.size) return "download"
        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else 0
        val archive = pm.getPackageArchiveInfo(file.path, flags) ?: return "download"
        if (archive.packageName != context.packageName) return "package"
        if (archive.longVersionCode <= installedCode) return "old"
        if (Build.VERSION.SDK_INT >= 28) {
            val mine = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
            val theirs = archive.signingInfo
            if (mine == null || theirs == null || certificates(mine.apkContentsSigners) != certificates(theirs.apkContentsSigners)) return "signature"
        }
        return null
    }

    private fun certificates(signers: Array<android.content.pm.Signature>) =
        signers.map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) } }.toSet()

    private fun commit(file: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            // An update by the app that installed it can go without a question on newer Android; where it cannot, the system asks
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            file.inputStream().use { input ->
                session.openWrite("sapoche.apk", 0, file.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val intent = Intent(context, InstallResultReceiver::class.java).setAction(InstallResultReceiver.ACTION)
            // Mutable: the system adds the status to it
            val pending = PendingIntent.getBroadcast(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            session.commit(pending.intentSender)
        }
    }

    /** What the system installer answered; on success this process is usually gone before it arrives. */
    fun onInstallResult(status: Int, message: String?) {
        if (status == PackageInstaller.STATUS_SUCCESS) return
        EventLog.d("update", "installer said $status: $message")
        flow.value = flow.value.copy(
            phase = UpdateState.Phase.FAILED,
            error = when (status) {
                PackageInstaller.STATUS_FAILURE_ABORTED -> "aborted"
                PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "signature"
                PackageInstaller.STATUS_FAILURE_BLOCKED -> "blocked"
                PackageInstaller.STATUS_FAILURE_STORAGE -> "storage"
                else -> "install"
            },
        )
    }

    private fun saveRelease(release: Release) {
        prefs.edit()
            .putLong("update_code", release.versionCode)
            .putString("update_name", release.versionName)
            .putString("update_sha", release.sha256)
            .putLong("update_size", release.size)
            .putString("update_notes", release.notes)
            .putString("update_notes_vi", release.notesVi)
            .putString("update_file", release.file)
            .apply()
    }

    private fun loadRelease(): Release? {
        val code = prefs.getLong("update_code", 0)
        if (code == 0L) return null
        return Release(
            code,
            prefs.getString("update_name", "").orEmpty(),
            prefs.getString("update_sha", "").orEmpty(),
            prefs.getLong("update_size", 0),
            prefs.getString("update_notes", "").orEmpty(),
            prefs.getString("update_file", null) ?: "app-$code.apk",
            prefs.getString("update_notes_vi", "").orEmpty(),
        )
    }

    companion object {
        /** A check on opening the app is skipped when the last one was this recent. */
        const val CHECK_EVERY_MS = 12 * 60 * 60 * 1000L
        private const val KEY_CHECKED = "update_checked_at"
    }
}
