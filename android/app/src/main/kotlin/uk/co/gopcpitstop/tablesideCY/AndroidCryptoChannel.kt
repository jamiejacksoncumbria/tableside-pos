package uk.co.gopcpitstop.tablesideCY

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * Runs the hub's deliberately expensive PIN derivation through Android's JCA
 * provider without blocking Flutter's platform thread. Only six-digit PINs,
 * the signed snapshot's bounded iteration range, a 256-bit result and a
 * minimum 128-bit salt are accepted. The PIN and derived key never enter logs.
 */
class AndroidCryptoChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "tableside/android_crypto")
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "pbkdf2Sha256") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val pin = call.argument<String>("pin")
            val salt = call.argument<ByteArray>("salt")
            val iterations = call.argument<Int>("iterations")
            val bits = call.argument<Int>("bits")
            if (pin == null || !pin.matches(Regex("^\\d{6}$")) ||
                salt == null || salt.size < 16 ||
                iterations == null || iterations !in 200_000..2_000_000 ||
                bits != 256
            ) {
                result.error("INVALID_PBKDF2_INPUT", "The PIN verifier input is invalid.", null)
                return@setMethodCallHandler
            }

            worker.execute {
                try {
                    val spec = PBEKeySpec(pin.toCharArray(), salt, iterations, bits)
                    val hash = try {
                        SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
                            .generateSecret(spec)
                            .encoded
                    } finally {
                        spec.clearPassword()
                    }
                    mainHandler.post { result.success(hash) }
                } catch (_: Exception) {
                    mainHandler.post {
                        result.error(
                            "PBKDF2_FAILED",
                            "Android could not derive the offline PIN verifier.",
                            null,
                        )
                    }
                }
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}
