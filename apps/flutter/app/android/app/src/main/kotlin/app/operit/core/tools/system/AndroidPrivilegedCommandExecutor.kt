package app.operit.core.tools.system

import android.content.pm.PackageManager
import android.os.ParcelFileDescriptor
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku

/** Executes system commands through the selected, verified privileged transport. */
object AndroidPrivilegedCommandExecutor {
    private const val DEFAULT_COMMAND_TIMEOUT_MS = 60_000L

    fun execute(
        target: AndroidPrivilegedCommandTarget,
        command: String,
        timeoutMillis: Long = DEFAULT_COMMAND_TIMEOUT_MS,
        rootSettings: AndroidRootExecutionSettings = AndroidRootExecutionSettings(),
    ): AndroidPrivilegedCommandResult {
        require(command.isNotBlank()) { "privileged command must not be blank" }
        require(timeoutMillis > 0L) { "privileged command timeout must be positive" }
        return when (target) {
            AndroidPrivilegedCommandTarget.RootAuto,
            AndroidPrivilegedCommandTarget.RootLibsu,
            AndroidPrivilegedCommandTarget.RootExec -> AndroidRootShell.execute(target, command, timeoutMillis, rootSettings)
            AndroidPrivilegedCommandTarget.Shizuku -> executeWithShizuku(command, timeoutMillis)
        }
    }

    private fun executeWithShizuku(command: String, timeoutMillis: Long): AndroidPrivilegedCommandResult {
        val deadline = AndroidCommandDeadline(timeoutMillis)
        check(Shizuku.pingBinder()) { "Shizuku service is not running" }
        check(Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            "Shizuku permission is not granted"
        }
        val service = IShizukuService.Stub.asInterface(
            requireNotNull(Shizuku.getBinder()) { "Shizuku service binder is unavailable" },
        )
        val process = service.newProcess(arrayOf("/system/bin/sh", "-c", command), null, null)
        try {
            process.outputStream?.close()
            return AndroidCommandProcessRunner.collect(
                stdout = ParcelFileDescriptor.AutoCloseInputStream(process.inputStream),
                stderr = ParcelFileDescriptor.AutoCloseInputStream(process.errorStream),
                awaitExit = { process.waitFor() },
                destroy = { process.destroy() },
                timeoutMillis = deadline.remainingMillis(),
            )
        } catch (error: Exception) {
            runCatching { process.destroy() }
            throw error
        }
    }
}
