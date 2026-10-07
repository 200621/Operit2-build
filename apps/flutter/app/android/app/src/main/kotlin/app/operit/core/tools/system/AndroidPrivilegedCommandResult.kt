package app.operit.core.tools.system

import java.nio.charset.StandardCharsets

/** Explicit transports stay strict; RootAuto selects a verified Root transport. */
enum class AndroidPrivilegedCommandTarget {
    RootAuto,
    RootLibsu,
    RootExec,
    Shizuku,
}

/** Raw streams are retained for binary callers, including screenshots. */
data class AndroidPrivilegedCommandResult(
    val stdout: ByteArray,
    val stderr: ByteArray,
    val exitCode: Int,
) {
    fun stdoutText(): String = stdout.toString(StandardCharsets.UTF_8)
    fun stderrText(): String = stderr.toString(StandardCharsets.UTF_8)
}
