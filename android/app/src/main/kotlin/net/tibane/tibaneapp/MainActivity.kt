package net.tibane.tibaneapp

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.solana.mobilewalletadapter.clientlib.protocol.MobileWalletAdapterClient
import com.solana.mobilewalletadapter.clientlib.scenario.LocalAssociationIntentCreator
import com.solana.mobilewalletadapter.clientlib.scenario.LocalAssociationScenario
import com.solana.mobilewalletadapter.clientlib.scenario.Scenario
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "net.tibane.tibaneapp/mwa"
        private const val TAG = "TibaneMWA"
        private const val ASSOCIATION_REQUEST_CODE = 0
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingScenario: LocalAssociationScenario? = null
    private var pendingAction: String? = null
    private var pendingArgs: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "authorize" -> {
                    val identityUri = call.argument<String>("identityUri")
                    val iconUri = call.argument<String>("iconUri")
                    val identityName = call.argument<String>("identityName")
                    val cluster = call.argument<String>("cluster")
                    doMwaSession(result, "authorize", mapOf(
                        "identityUri" to identityUri,
                        "iconUri" to iconUri,
                        "identityName" to identityName,
                        "cluster" to cluster,
                    ))
                }
                "reauthorize" -> {
                    val identityUri = call.argument<String>("identityUri")
                    val identityName = call.argument<String>("identityName")
                    val authToken = call.argument<String>("authToken")
                    doMwaSession(result, "reauthorize", mapOf(
                        "identityUri" to identityUri,
                        "identityName" to identityName,
                        "authToken" to authToken,
                    ))
                }
                "signAndSendTransactions" -> {
                    val identityUri = call.argument<String>("identityUri")
                    val identityName = call.argument<String>("identityName")
                    val authToken = call.argument<String>("authToken")
                    val transactions = call.argument<List<ByteArray>>("transactions")
                    doMwaSession(result, "signAndSendTransactions", mapOf(
                        "identityUri" to identityUri,
                        "identityName" to identityName,
                        "authToken" to authToken,
                        "transactions" to transactions,
                    ))
                }
                "signTransactions" -> {
                    val identityUri = call.argument<String>("identityUri")
                    val identityName = call.argument<String>("identityName")
                    val authToken = call.argument<String>("authToken")
                    val transactions = call.argument<List<ByteArray>>("transactions")
                    doMwaSession(result, "signTransactions", mapOf(
                        "identityUri" to identityUri,
                        "identityName" to identityName,
                        "authToken" to authToken,
                        "transactions" to transactions,
                    ))
                }
                "signMessages" -> {
                    val identityUri = call.argument<String>("identityUri")
                    val identityName = call.argument<String>("identityName")
                    val authToken = call.argument<String>("authToken")
                    val messages = call.argument<List<ByteArray>>("messages")
                    doMwaSession(result, "signMessages", mapOf(
                        "identityUri" to identityUri,
                        "identityName" to identityName,
                        "authToken" to authToken,
                        "messages" to messages,
                    ))
                }
                "deauthorize" -> {
                    val identityUri = call.argument<String>("identityUri")
                    val identityName = call.argument<String>("identityName")
                    val authToken = call.argument<String>("authToken")
                    doMwaSession(result, "deauthorize", mapOf(
                        "identityUri" to identityUri,
                        "identityName" to identityName,
                        "authToken" to authToken,
                    ))
                }
                "hasMwaWallet" -> {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse("solana-wallet:/v1/associate/local"))
                    val resolved = packageManager.resolveActivity(intent, 0)
                    result.success(resolved != null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun doMwaSession(result: MethodChannel.Result, action: String, args: Map<String, Any?>) {
        Log.d(TAG, "doMwaSession: action=$action")

        // Bail out early when no MWA wallet is installed — otherwise we'd
        // build a scenario, allocate a port, then explode when the OS can't
        // find a handler for solana-wallet:.
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("solana-wallet:/v1/associate/local"))
        if (packageManager.resolveActivity(probe, 0) == null) {
            Log.w(TAG, "No MWA wallet installed on device")
            result.error(
                "NO_WALLET",
                "No Solana wallet app is installed. Install Phantom, Solflare, or use Tibane's in-app wallet.",
                null,
            )
            return
        }

        pendingResult = result
        pendingAction = action
        pendingArgs = args

        val scenario: LocalAssociationScenario
        try {
            scenario = LocalAssociationScenario(Scenario.DEFAULT_CLIENT_TIMEOUT_MS)
            pendingScenario = scenario

            // Fire the association intent to launch the wallet UI
            val associationIntent = LocalAssociationIntentCreator.createAssociationIntent(
                null,
                scenario.port,
                scenario.session,
            )
            Log.d(TAG, "Starting wallet activity, port=${scenario.port}")
            startActivityForResult(associationIntent, ASSOCIATION_REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            // Race: resolveActivity said yes a moment ago but the resolver
            // disappeared (uninstall, profile switch). Treat the same as the
            // pre-check NO_WALLET case.
            Log.w(TAG, "Wallet handler vanished between probe and start", e)
            pendingScenario?.let { try { it.close() } catch (_: Exception) {} }
            pendingScenario = null
            result.error(
                "NO_WALLET",
                "No Solana wallet app is installed. Install Phantom, Solflare, or use Tibane's in-app wallet.",
                null,
            )
            pendingResult = null
            return
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create MWA session", e)
            pendingScenario?.let { try { it.close() } catch (_: Exception) {} }
            pendingScenario = null
            result.error("MWA_ERROR", e.message, null)
            pendingResult = null
            return
        }

        // Start the client connection in a background thread
        // The wallet will start its WebSocket server, then our client connects
        Thread {
            try {
                Log.d(TAG, "Waiting for MWA client connection...")
                val client = scenario.start().get(60, TimeUnit.SECONDS)
                Log.d(TAG, "MWA client connected!")

                val response = executeAction(client, action, args)
                Log.d(TAG, "MWA action complete: $response")

                runOnUiThread {
                    pendingResult?.success(response)
                    pendingResult = null
                }
            } catch (e: TimeoutException) {
                Log.e(TAG, "MWA connection timeout", e)
                runOnUiThread {
                    pendingResult?.error("TIMEOUT", "Wallet connection timed out", null)
                    pendingResult = null
                }
            } catch (e: ExecutionException) {
                Log.e(TAG, "MWA error", e)
                runOnUiThread {
                    pendingResult?.error("MWA_ERROR", e.cause?.message ?: e.message, null)
                    pendingResult = null
                }
            } catch (e: Exception) {
                Log.e(TAG, "MWA error", e)
                runOnUiThread {
                    pendingResult?.error("MWA_ERROR", e.message, null)
                    pendingResult = null
                }
            } finally {
                try {
                    scenario.close()
                    Log.d(TAG, "Scenario closed")
                } catch (e: Exception) {
                    Log.e(TAG, "Error closing scenario", e)
                }
                pendingScenario = null
            }
        }.start()
    }

    /**
     * Attempt reauthorize; if it fails, fall back to a fresh authorize.
     * This handles expired or invalidated auth tokens gracefully.
     */
    private fun reauthorizeOrAuthorize(
        client: MobileWalletAdapterClient,
        args: Map<String, Any?>
    ): com.solana.mobilewalletadapter.clientlib.protocol.MobileWalletAdapterClient.AuthorizationResult {
        val identityUri = args["identityUri"]?.let { Uri.parse(it as String) }
        val identityName = args["identityName"] as? String
        val authToken = args["authToken"] as? String

        if (authToken != null) {
            try {
                Log.d(TAG, "Attempting reauthorize...")
                val reauth = client.reauthorize(identityUri, null, identityName, authToken).get()
                Log.d(TAG, "Reauthorize OK")
                return reauth
            } catch (e: Exception) {
                Log.w(TAG, "Reauthorize failed, falling back to authorize: ${e.message}")
            }
        }

        Log.d(TAG, "Performing fresh authorize...")
        val iconUri = args["iconUri"]?.let {
            val uri = Uri.parse(it as String)
            if (uri.isAbsolute) Uri.parse(uri.path?.removePrefix("/") ?: "favicon.ico")
            else uri
        } ?: Uri.parse("favicon.ico")
        val auth = client.authorize(identityUri, iconUri, identityName, args["cluster"] as? String ?: "mainnet-beta").get()
        Log.d(TAG, "Fresh authorize OK: token=${auth.authToken}")
        return auth
    }

    private fun executeAction(
        client: MobileWalletAdapterClient,
        action: String,
        args: Map<String, Any?>
    ): Map<String, Any?> {
        return when (action) {
            "authorize" -> {
                Log.d(TAG, "Calling authorize...")
                val iconUri = args["iconUri"]?.let {
                    val uri = Uri.parse(it as String)
                    // MWA 2.x requires relative URI for icon
                    if (uri.isAbsolute) Uri.parse(uri.path?.removePrefix("/") ?: "favicon.ico")
                    else uri
                }
                val authResult = client.authorize(
                    args["identityUri"]?.let { Uri.parse(it as String) },
                    iconUri,
                    args["identityName"] as? String,
                    args["cluster"] as? String,
                ).get()
                Log.d(TAG, "Authorize result: token=${authResult.authToken}, label=${authResult.accountLabel}")
                mapOf(
                    "authToken" to authResult.authToken,
                    "publicKey" to authResult.publicKey,
                    "accountLabel" to authResult.accountLabel,
                    "walletUriBase" to authResult.walletUriBase?.toString(),
                )
            }
            "reauthorize" -> {
                Log.d(TAG, "Calling reauthorize...")
                val authResult = client.reauthorize(
                    args["identityUri"]?.let { Uri.parse(it as String) },
                    null,
                    args["identityName"] as? String,
                    args["authToken"] as String,
                ).get()
                Log.d(TAG, "Reauthorize result: token=${authResult.authToken}")
                mapOf(
                    "authToken" to authResult.authToken,
                    "publicKey" to authResult.publicKey,
                    "accountLabel" to authResult.accountLabel,
                )
            }
            "signAndSendTransactions" -> {
                val auth = reauthorizeOrAuthorize(client, args)

                @Suppress("UNCHECKED_CAST")
                val transactions = args["transactions"] as List<ByteArray>
                Log.d(TAG, "Signing and sending ${transactions.size} transactions...")
                val result = client.signAndSendTransactions(
                    transactions.toTypedArray(),
                    null,
                ).get()
                Log.d(TAG, "Sign result: ${result.signatures.size} signatures")
                mapOf(
                    "authToken" to auth.authToken,
                    "publicKey" to auth.publicKey,
                    "signatures" to result.signatures.toList(),
                )
            }
            "signTransactions" -> {
                val auth = reauthorizeOrAuthorize(client, args)

                @Suppress("UNCHECKED_CAST")
                val transactions = args["transactions"] as List<ByteArray>
                Log.d(TAG, "Signing ${transactions.size} transactions (sign-only)...")
                val result = client.signTransactions(
                    transactions.toTypedArray(),
                ).get()
                Log.d(TAG, "Sign-only result: ${result.signedPayloads.size} signed payloads")
                mapOf(
                    "authToken" to auth.authToken,
                    "publicKey" to auth.publicKey,
                    "signedTransactions" to result.signedPayloads.toList(),
                )
            }
            "signMessages" -> {
                val auth = reauthorizeOrAuthorize(client, args)

                @Suppress("UNCHECKED_CAST")
                val messages = args["messages"] as List<ByteArray>
                Log.d(TAG, "Signing ${messages.size} messages...")
                val addresses = arrayOf(auth.publicKey)
                val result = client.signMessagesDetached(
                    messages.toTypedArray(),
                    addresses,
                ).get()
                Log.d(TAG, "signMessages result: ${result.messages.size} signed messages")
                mapOf(
                    "authToken" to auth.authToken,
                    "publicKey" to auth.publicKey,
                    "signatures" to result.messages.map { it.signatures[0] },
                )
            }
            "deauthorize" -> {
                Log.d(TAG, "Calling deauthorize...")
                client.deauthorize(args["authToken"] as String).get()
                mapOf("success" to true)
            }
            else -> throw IllegalArgumentException("Unknown action: $action")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ASSOCIATION_REQUEST_CODE) {
            Log.d(TAG, "onActivityResult: resultCode=$resultCode")
        }
    }
}
