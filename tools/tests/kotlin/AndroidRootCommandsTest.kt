package app.operit.core.tools.system

import java.io.ByteArrayInputStream
import java.nio.file.Files
import java.util.concurrent.TimeoutException
import kotlin.system.measureTimeMillis

private fun result(output: String = "", error: String = "", code: Int = 0) =
    AndroidPrivilegedCommandResult(output.toByteArray(), error.toByteArray(), code)

private class FakeRootBackend : AndroidRootCommandBackend {
    val calls = mutableListOf<String>()
    val processArguments = mutableListOf<List<String>>()
    var version = "Magisk 28.0"
    var libsuGranted = true
    var execGranted = true
    var libsuError: Exception? = null
    var processError: Exception? = null
    var userCommandError: Exception? = null
    var identityOutput: String? = null
    var identityExitCode = 0
    var probeDelayMillis = 0L
    var userCommands = 0
    var userTimeoutMillis = 0L

    override fun executeLibsu(command: String, timeoutMillis: Long): AndroidPrivilegedCommandResult {
        calls.add("libsu:$command")
        if (command == "id -u") {
            libsuError?.let { throw it }
            if (probeDelayMillis > 0) Thread.sleep(probeDelayMillis)
            return if (libsuGranted) result(identityOutput ?: "0\n", code = identityExitCode) else result("2000\n")
        }
        return userCommand(timeoutMillis)
    }

    override fun executeProcess(arguments: List<String>, timeoutMillis: Long): AndroidPrivilegedCommandResult {
        processArguments.add(arguments)
        calls.add("exec:${arguments.last()}")
        processError?.let { throw it }
        if (arguments.last() == "--version") return result(version)
        if (arguments.last() == "id -u") return if (execGranted) result(identityOutput ?: "0\n", code = identityExitCode) else result("2000\n")
        return userCommand(timeoutMillis)
    }

    private fun userCommand(timeoutMillis: Long): AndroidPrivilegedCommandResult {
        userCommands++
        userTimeoutMillis = timeoutMillis
        userCommandError?.let { throw it }
        return result("done")
    }
}

private inline fun <reified T : Throwable> fails(action: () -> Unit) {
    try { action() } catch (error: Throwable) {
        check(error is T) { "Expected ${T::class.simpleName}, got $error" }
        return
    }
    error("Expected ${T::class.simpleName}")
}

fun main() {
    var tests = 0
    fun test(name: String, action: () -> Unit) {
        action()
        tests++
        println("PASS $name")
    }
    val auto = AndroidRootExecutionSettings()
    test("argv supports custom paths, quotes and escaped whitespace without shell expansion") {
        check(AndroidRootExecutionSettings(suCommand = " '/path with spaces/su' --flag \"quoted arg\" one\\ two").suArguments() ==
            listOf("/path with spaces/su", "--flag", "quoted arg", "one two"))
        check(AndroidRootExecutionSettings(suCommand = "  ").suArguments() == listOf("su"))
        check(AndroidRootExecutionSettings(suCommand = "su \$(touch /tmp/not-executed)").suArguments() ==
            listOf("su", "\$(touch", "/tmp/not-executed)"))
        for (invalid in listOf("'unfinished", "su\\", "''", "su\n-c", "su\u0000")) {
            fails<IllegalArgumentException> { AndroidRootExecutionSettings(suCommand = invalid).suArguments() }
        }
    }
    test("Magisk selects libsu; --version success alone is not KernelSU") {
        val backend = FakeRootBackend()
        val status = AndroidRootCommandRouter(backend).checkAccess(auto, 1_000)
        check(status.granted && status.target == AndroidPrivilegedCommandTarget.RootLibsu)
        check(backend.calls == listOf("exec:--version", "libsu:id -u"))
    }
    test("KernelSU and APatch prefer direct exec") {
        for (version in listOf("KernelSU 12345", "apatch 111")) {
            val backend = FakeRootBackend().apply { this.version = version }
            val status = AndroidRootCommandRouter(backend).checkAccess(auto, 1_000)
            check(status.target == AndroidPrivilegedCommandTarget.RootExec)
            check(backend.calls.none { it.startsWith("libsu:") })
        }
    }
    test("libsu failure falls back to exec only during Root identity probing") {
        val backend = FakeRootBackend().apply { libsuError = IllegalStateException("not supported") }
        val status = AndroidRootCommandRouter(backend).checkAccess(auto, 1_000)
        check(status.granted && status.target == AndroidPrivilegedCommandTarget.RootExec)
        check(status.diagnostics.any { it.contains("not supported") })
    }
    test("forced modes never try the other transport or version discovery") {
        for (mode in listOf(AndroidRootExecutionMode.ForceLibsu, AndroidRootExecutionMode.ForceExec)) {
            val backend = FakeRootBackend().apply { libsuGranted = false; execGranted = false }
            val status = AndroidRootCommandRouter(backend).checkAccess(AndroidRootExecutionSettings(mode), 1_000)
            check(!status.granted)
            check(backend.calls.size == 1)
            check(backend.calls.single().startsWith(if (mode == AndroidRootExecutionMode.ForceLibsu) "libsu:" else "exec:"))
        }
    }
    test("Root presence and permission are different; nonzero UID is denied") {
        val backend = FakeRootBackend().apply { libsuGranted = false; execGranted = false }
        val status = AndroidRootCommandRouter(backend).checkAccess(auto, 1_000)
        check(status.deviceRooted && !status.granted)
    }
    test("misleading UID output and exit failures cannot grant Root") {
        for (output in listOf("00", "uid=0(root)", "0\nmanager banner", "1000")) {
            val backend = FakeRootBackend().apply { identityOutput = output }
            check(!AndroidRootCommandRouter(backend).checkAccess(auto, 1_000).granted)
        }
        val backend = FakeRootBackend().apply { identityExitCode = 1 }
        check(!AndroidRootCommandRouter(backend).checkAccess(auto, 1_000).granted)
    }
    test("missing su and unavailable libsu report denied with diagnostics") {
        val backend = FakeRootBackend().apply {
            libsuError = IllegalStateException("no Root shell")
            processError = java.io.IOException("su not found")
        }
        val status = AndroidRootCommandRouter(backend).checkAccess(auto, 1_000)
        check(!status.granted && status.diagnostics.any { it.contains("su not found") })
    }
    test("positive permission is rechecked and revoked grants are not cached") {
        val backend = FakeRootBackend()
        val router = AndroidRootCommandRouter(backend)
        check(router.checkAccess(auto, 1_000).granted)
        backend.libsuGranted = false; backend.execGranted = false
        check(!router.checkAccess(auto, 1_000).granted)
        backend.execGranted = true
        check(router.checkAccess(auto, 1_000).granted)
        check(backend.calls.count { it == "libsu:id -u" } == 3)
    }
    test("changing forced mode and custom su invalidates cached transport") {
        val backend = FakeRootBackend()
        val router = AndroidRootCommandRouter(backend)
        check(router.checkAccess(auto, 1_000).target == AndroidPrivilegedCommandTarget.RootLibsu)
        val settings = AndroidRootExecutionSettings(AndroidRootExecutionMode.ForceExec, "'/custom path/su' --flag")
        check(router.checkAccess(settings, 1_000).target == AndroidPrivilegedCommandTarget.RootExec)
        check(backend.processArguments.last() == listOf("/custom path/su", "--flag", "-c", "id -u"))
    }
    test("failed user command is never retried through another Root transport") {
        val backend = FakeRootBackend().apply { userCommandError = TimeoutException("may already have side effects") }
        val router = AndroidRootCommandRouter(backend)
        fails<TimeoutException> { router.execute(AndroidPrivilegedCommandTarget.RootAuto, "touch /important", 1_000, auto) }
        check(backend.userCommands == 1)
        check(backend.calls.none { it.startsWith("exec:if") })
    }
    test("explicit exec preserves payload and checks actual UID in the same process") {
        val backend = FakeRootBackend()
        val payload = "printf '%s' 'some | quoted $ text'"
        AndroidRootCommandRouter(backend).execute(AndroidPrivilegedCommandTarget.RootExec, payload, 1_000, auto)
        val command = backend.processArguments.single().last()
        check(command.startsWith("if [ \"\$(id -u)\" != 0 ]"))
        check(command.endsWith("\n$payload") && backend.userCommands == 1)
    }
    test("transport selection consumes the command deadline rather than resetting it") {
        val backend = FakeRootBackend().apply { probeDelayMillis = 80 }
        AndroidRootCommandRouter(backend).execute(AndroidPrivilegedCommandTarget.RootAuto, "echo done", 200, auto)
        check(backend.userTimeoutMillis in 1..150)
    }
    test("expired identity check does not launch the user command") {
        val backend = FakeRootBackend().apply { probeDelayMillis = 50 }
        fails<TimeoutException> {
            AndroidRootCommandRouter(backend).execute(AndroidPrivilegedCommandTarget.RootAuto, "touch /important", 20, auto)
        }
        check(backend.userCommands == 0)
    }
    test("a timed-out failed identity probe reports timeout, not permission denial") {
        val backend = FakeRootBackend().apply { probeDelayMillis = 50; libsuGranted = false; execGranted = false }
        fails<TimeoutException> {
            AndroidRootCommandRouter(backend).execute(AndroidPrivilegedCommandTarget.RootAuto, "touch /important", 20, auto)
        }
        check(backend.userCommands == 0)
    }
    test("interruption is propagated rather than treated as a fallback reason") {
        val backend = FakeRootBackend().apply { libsuError = InterruptedException("cancel") }
        try {
            fails<InterruptedException> { AndroidRootCommandRouter(backend).checkAccess(auto, 1_000) }
            check(Thread.currentThread().isInterrupted)
            check(backend.calls.none { it == "exec:id -u" })
        } finally { Thread.interrupted() }
    }
    test("process runner drains large stdout and stderr concurrently") {
        val output = AndroidCommandProcessRunner.execute(
            listOf("/bin/sh", "-c", "i=0; while [ \$i -lt 4000 ]; do printf 'output-line\\n'; printf 'error-line\\n' >&2; i=\$((i+1)); done"), 5_000,
        )
        check(output.exitCode == 0 && output.stdout.size == 48_000 && output.stderr.size == 44_000)
    }
    test("process runner closes stdin so noninteractive wrappers can see EOF") {
        val output = AndroidCommandProcessRunner.execute(listOf("/bin/sh", "-c", "cat >/dev/null; printf done"), 1_000)
        check(output.stdoutText() == "done")
    }
    test("binary stdout and nonzero exit codes are preserved") {
        val output = AndroidCommandProcessRunner.execute(listOf("/bin/sh", "-c", "printf '\\000\\001\\377'; printf error >&2; exit 7"), 1_000)
        check(output.stdout.contentEquals(byteArrayOf(0, 1, -1)))
        check(output.stderrText() == "error" && output.exitCode == 7)
    }
    test("timeout destroys a hung process and prevents delayed side effects") {
        val marker = Files.createTempFile("operit-root-timeout", ".txt")
        Files.delete(marker)
        try {
            val elapsed = measureTimeMillis {
                fails<TimeoutException> {
                    AndroidCommandProcessRunner.execute(
                        listOf("/bin/sh", "-c", "sleep 1; printf bad > '$marker'"), 80,
                    )
                }
            }
            check(elapsed < 800) { "timeout took $elapsed ms" }
            Thread.sleep(1_100)
            check(!Files.exists(marker))
        } finally { Files.deleteIfExists(marker) }
    }
    test("collection failure cleans up process and both streams") {
        var destroyed = false
        val closed = java.util.concurrent.atomic.AtomicInteger()
        fun stream() = object : ByteArrayInputStream(byteArrayOf()) {
            override fun close() { closed.incrementAndGet(); super.close() }
        }
        fails<IllegalStateException> {
            AndroidCommandProcessRunner.collect(stream(), stream(), { error("wait failed") }, { destroyed = true }, 1_000)
        }
        check(destroyed && closed.get() >= 2)
    }
    println("$tests Root command regression tests passed")
}
