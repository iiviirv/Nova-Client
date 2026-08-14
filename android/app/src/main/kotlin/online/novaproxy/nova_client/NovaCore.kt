package online.novaproxy.nova_client

import android.content.Context
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File

/**
 * One-time libbox setup, plus the capability probe that keeps the Dart layer and
 * the bundled core honest about each other.
 *
 * Why the probe exists: the Dart side has emitted a fully correct AmneziaWG
 * (`awg`) endpoint since the config layer was written, while every core built
 * from stock SagerNet sing-box has no AmneziaWG in it at all. The two disagreed
 * in silence: the app produced a valid document, the core refused it, and the
 * only visible symptom was a tunnel that never carried traffic. [supportsAwg]
 * asks the core the question directly instead, by handing it a minimal `awg`
 * endpoint and seeing whether it can build it:
 *
 *   * a core built with `-tags with_awg` accepts it,
 *   * a core built without the tag answers "Awg is not included in this build",
 *   * a stock core, which does not know the type at all, fails to decode it.
 *
 * Only the first case reports support, so a core that ever loses AmneziaWG is
 * visible immediately rather than after a support ticket.
 */
object NovaCore {

    /**
     * A minimal AmneziaWG endpoint carrying the junk parameters an obfuscated
     * peer uses. Nothing here is dialled: [Libbox.checkConfig] builds the
     * document and closes it again, so the keys are placeholders and the peer
     * address is loopback.
     */
    private const val AWG_PROBE = """
        {"endpoints":[{"type":"awg","tag":"nova-awg-probe",
        "private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "address":["10.0.0.2/32"],"mtu":1408,
        "jc":4,"jmin":40,"jmax":70,"s1":15,"s2":20,"h1":"1","h2":"2","h3":"3","h4":"4",
        "peers":[{"public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "address":"127.0.0.1","port":51820,"allowed_ips":["0.0.0.0/0"],
        "persistent_keepalive_interval":25}]}]}
    """

    @Volatile
    private var setupDone = false

    @Volatile
    private var awgSupported: Boolean? = null

    @Volatile
    private var awgProbed = false

    @Volatile
    private var awgReason: String? = null

    /**
     * Initialise libbox once per process. Both the tunnel service and the
     * capability probe need it, and calling it twice throws, so it lives here
     * rather than in either caller.
     */
    @Synchronized
    fun ensureSetup(context: Context) {
        if (setupDone) return
        val working = File(context.filesDir, "working").apply { mkdirs() }
        Libbox.setup(
            SetupOptions().apply {
                setBasePath(context.filesDir.absolutePath)
                setWorkingPath(working.absolutePath)
                setTempPath(context.cacheDir.absolutePath)
                setCommandServerListenPort(0)
            },
        )
        setupDone = true
    }

    /** The core's own version string, for the about screen and bug reports. */
    fun version(): String = runCatching { Libbox.version() }.getOrDefault("")

    /**
     * True when the bundled core can build an AmneziaWG endpoint, false when it
     * says it cannot, and null when the question could not be answered. Cached:
     * the answer is a property of the binary and cannot change while it runs.
     * Never call from the main thread, it builds and tears down a small
     * userspace network stack.
     *
     * Only an error that names the endpoint type counts as a "no". Anything
     * else (setup failing, memory pressure while the stack is built) is an
     * unanswered question, because a wrong refusal locks a customer out of a
     * protocol their build actually has, and on a censored network that costs
     * them more than a failed attempt does.
     */
    @Synchronized
    fun supportsAwg(context: Context): Boolean? {
        if (awgProbed) return awgSupported
        runCatching {
            ensureSetup(context)
            Libbox.checkConfig(AWG_PROBE)
        }.fold(
            onSuccess = {
                awgSupported = true
                awgProbed = true
            },
            onFailure = { error ->
                val message = error.message ?: error.toString()
                awgReason = message
                if (message.contains("awg", ignoreCase = true)) {
                    awgSupported = false
                    awgProbed = true
                }
            },
        )
        return awgSupported
    }

    /** Why the core refused AmneziaWG, when it did. Null while it supports it. */
    fun awgFailureReason(): String? = awgReason
}
