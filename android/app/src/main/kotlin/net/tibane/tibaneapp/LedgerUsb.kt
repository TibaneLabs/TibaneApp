package net.tibane.tibaneapp

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * A Ledger hardware wallet over USB-OTG, driven as USB host.
 *
 * Ledger devices expose a vendor HID interface (usage page 0xFFA0) with one
 * interrupt IN and one interrupt OUT endpoint. APDUs travel in Ledger's HID
 * framing: 64-byte packets, each `channel (0x0101, BE) | tag 0x05 | sequence
 * (BE u16)`, the first packet's payload starting with the APDU length (BE u16),
 * zero-padded. Answers come back framed the same way. The framing mirrors
 * `lib/services/ledger/ledger_framing.dart` (which is unit tested); everything
 * above the APDU is libwallet's.
 */
class LedgerUsb(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "LedgerUsb"
        const val METHOD_CHANNEL = "net.tibane.tibaneapp/ledger"

        const val VENDOR_ID = 0x2C97
        private const val HID_CLASS = 0x03
        private const val LEDGER_USAGE_PAGE = 0xFFA0

        private const val ACTION_PERMISSION = "net.tibane.tibaneapp.LEDGER_USB_PERMISSION"

        private const val PACKET = 64
        private const val CHANNEL = 0x0101
        private const val TAG_APDU = 0x05
        private const val WRITE_TIMEOUT_MS = 2_000
        /** One read slice; the loop re-checks for close/detach between slices. */
        private const val READ_SLICE_MS = 250
        /** A user may take a while to confirm on the device; libwallet waits five minutes. */
        private const val EXCHANGE_TIMEOUT_MS = 5 * 60 * 1000L
    }

    /** [unsent]: failed before any byte of the APDU reached the device, so it may be resent. */
    private class UsbError(val code: String, message: String, val unsent: Boolean = false) : IOException(message)

    private val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    // Written on the io thread; read by close()/detach from the main thread.
    @Volatile private var connection: UsbDeviceConnection? = null
    @Volatile private var device: UsbDevice? = null
    private var iface: UsbInterface? = null
    private var endpointIn: UsbEndpoint? = null
    private var endpointOut: UsbEndpoint? = null

    /** Set to abort an exchange that is waiting for the device. */
    @Volatile private var aborting = false
    @Volatile private var detached = false

    private var detachReceiver: BroadcastReceiver? = null
    private var permissionPending = false

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
    }

    fun dispose() {
        aborting = true
        io.execute { release() }
        io.shutdown()
    }

    // ---- discovery ----------------------------------------------------------------

    private fun hidInterfaces(device: UsbDevice): List<UsbInterface> =
        (0 until device.interfaceCount).map { device.getInterface(it) }.filter { candidate ->
            candidate.interfaceClass == HID_CLASS && endpoints(candidate) != null
        }

    /** The interrupt IN / OUT pair, or null when the interface lacks one. */
    private fun endpoints(candidate: UsbInterface): Pair<UsbEndpoint, UsbEndpoint>? {
        var inEp: UsbEndpoint? = null
        var outEp: UsbEndpoint? = null
        for (k in 0 until candidate.endpointCount) {
            val ep = candidate.getEndpoint(k)
            if (ep.type != UsbConstants.USB_ENDPOINT_XFER_INT) continue
            if (ep.direction == UsbConstants.USB_DIR_IN) inEp = ep else outEp = ep
        }
        return if (inEp != null && outEp != null) Pair(inEp, outEp) else null
    }

    private fun ledgers(): List<UsbDevice> = manager.deviceList.values.filter {
        it.vendorId == VENDOR_ID && hidInterfaces(it).isNotEmpty()
    }

    /** The product id's high byte names the model (as `@ledgerhq/devices` maps it). */
    private fun modelName(productId: Int): String = when (productId shr 8) {
        0x00, 0x10 -> "Ledger Nano S"
        0x40 -> "Ledger Nano X"
        0x50 -> "Ledger Nano S Plus"
        0x60 -> "Ledger Stax"
        0x70 -> "Ledger Flex"
        0x80 -> "Ledger Nano Gen5"
        else -> "Ledger"
    }

    private fun describe(d: UsbDevice): Map<String, Any?> {
        val product = try {
            d.productName
        } catch (_: SecurityException) {
            null
        }
        return mapOf(
            "id" to d.deviceName,
            "name" to (product?.takeIf { it.isNotBlank() } ?: modelName(d.productId)),
            "productId" to d.productId,
        )
    }

    // ---- method channel -----------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
            )
            "list" -> result.success(ledgers().map { describe(it) })
            "open" -> open(call.argument<String>("id"), result)
            "exchange" -> {
                val apdu = call.argument<ByteArray>("apdu")
                if (apdu == null || apdu.size > 0xFFFF) {
                    result.error("BAD_ARGS", "exchange needs an APDU of at most 65535 bytes.", null)
                    return
                }
                io.execute {
                    try {
                        val reply = exchange(apdu)
                        main.post { result.success(reply) }
                    } catch (e: UsbError) {
                        Log.w(TAG, "exchange failed: ${e.code} ${e.message}")
                        main.post { result.error(e.code, e.message, if (e.unsent) "unsent" else null) }
                    } catch (e: Exception) {
                        Log.w(TAG, "exchange failed", e)
                        main.post { result.error(failureCode(), e.message, null) }
                    }
                }
            }
            "close" -> {
                // Abort a pending read first; it re-checks every READ_SLICE_MS.
                aborting = true
                io.execute {
                    release()
                    main.post { result.success(null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun open(id: String?, result: MethodChannel.Result) {
        val target = ledgers().firstOrNull { id == null || it.deviceName == id }
        if (target == null) {
            result.error("NO_DEVICE", "No Ledger is plugged in.", null)
            return
        }
        if (manager.hasPermission(target)) {
            openGranted(target, result)
            return
        }
        if (permissionPending) {
            result.error("IO", "A USB permission request is already showing.", null)
            return
        }
        permissionPending = true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != ACTION_PERMISSION) return
                try {
                    context.unregisterReceiver(this)
                } catch (_: IllegalArgumentException) {
                }
                permissionPending = false
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (granted) {
                    openGranted(target, result)
                } else {
                    result.error("PERMISSION_DENIED", "USB access to the Ledger was not allowed.", null)
                }
            }
        }
        val filter = IntentFilter(ACTION_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        // Mutable: the system adds the device and the grant as extras.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        val intent = Intent(ACTION_PERMISSION).setPackage(context.packageName)
        manager.requestPermission(target, PendingIntent.getBroadcast(context, 1, intent, flags))
    }

    private fun openGranted(target: UsbDevice, result: MethodChannel.Result) {
        io.execute {
            try {
                release()
                aborting = false
                detached = false
                val conn = manager.openDevice(target) ?: throw UsbError("IO", "Could not open the Ledger.")
                val candidate = pickInterface(conn, target)
                if (candidate == null) {
                    conn.close()
                    throw UsbError("UNSUPPORTED", "The Ledger has no HID interface.")
                }
                if (!conn.claimInterface(candidate, true)) {
                    conn.close()
                    throw UsbError("IO", "Could not claim the Ledger's HID interface.")
                }
                val (inEp, outEp) = endpoints(candidate)!!
                connection = conn
                device = target
                iface = candidate
                endpointIn = inEp
                endpointOut = outEp
                main.post {
                    watchDetach(target)
                    result.success(describe(target))
                }
            } catch (e: UsbError) {
                Log.w(TAG, "open failed: ${e.message}")
                release()
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                Log.w(TAG, "open failed", e)
                release()
                main.post { result.error("IO", e.message, null) }
            }
        }
    }

    /**
     * The interface carrying APDUs. With U2F/FIDO enabled the device has a
     * second HID interface (usage page 0xF1D0), so prefer the one whose report
     * descriptor declares Ledger's usage page 0xFFA0, then interface 0 (where
     * Ledger puts it), then any HID interface with interrupt endpoints.
     */
    private fun pickInterface(conn: UsbDeviceConnection, target: UsbDevice): UsbInterface? {
        val candidates = hidInterfaces(target)
        for (candidate in candidates) {
            if (usagePage(conn, candidate) == LEDGER_USAGE_PAGE) return candidate
        }
        return candidates.firstOrNull { it.id == 0 } ?: candidates.firstOrNull()
    }

    /** The first Usage Page item of the interface's HID report descriptor, if readable. */
    private fun usagePage(conn: UsbDeviceConnection, candidate: UsbInterface): Int? {
        return try {
            val buf = ByteArray(256)
            // GET_DESCRIPTOR (standard, interface recipient), type 0x22 = HID report.
            val n = conn.controlTransfer(0x81, 0x06, 0x2200, candidate.id, buf, buf.size, 1_000)
            if (n < 3) return null
            // Usage Page is a global item, tag 0x04: 0x05 (1 byte) or 0x06 (2 bytes, LE).
            when (buf[0].toInt() and 0xFF) {
                0x05 -> buf[1].toInt() and 0xFF
                0x06 -> (buf[1].toInt() and 0xFF) or ((buf[2].toInt() and 0xFF) shl 8)
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun watchDetach(target: UsbDevice) {
        unwatchDetach()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != UsbManager.ACTION_USB_DEVICE_DETACHED) return
                @Suppress("DEPRECATION")
                val gone: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
                if (gone == null || gone.deviceName == target.deviceName) {
                    detached = true
                    aborting = true
                    try {
                        io.execute { release() }
                    } catch (_: java.util.concurrent.RejectedExecutionException) {
                    }
                }
            }
        }
        val filter = IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        detachReceiver = receiver
    }

    private fun unwatchDetach() {
        val receiver = detachReceiver ?: return
        detachReceiver = null
        main.post {
            try {
                context.unregisterReceiver(receiver)
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    /** Runs on the io thread. */
    private fun release() {
        val conn = connection
        connection = null
        device = null
        if (conn != null) {
            try {
                iface?.let { conn.releaseInterface(it) }
            } catch (_: Exception) {
            }
            try {
                conn.close()
            } catch (_: Exception) {
            }
        }
        iface = null
        endpointIn = null
        endpointOut = null
        unwatchDetach()
    }

    private fun stillAttached(): Boolean {
        if (detached) return false
        val d = device ?: return false
        return manager.deviceList.values.any { it.deviceName == d.deviceName }
    }

    private fun failureCode(): String = if (stillAttached()) "IO" else "DISCONNECTED"

    // ---- HID framing --------------------------------------------------------------

    /** Runs on the io thread: one APDU out, one whole answer (status word included) back. */
    private fun exchange(apdu: ByteArray): ByteArray {
        val conn = connection ?: throw UsbError("DISCONNECTED", "The Ledger is not open.", unsent = true)
        val outEp = endpointOut ?: throw UsbError("DISCONNECTED", "The Ledger is not open.", unsent = true)
        val inEp = endpointIn ?: throw UsbError("DISCONNECTED", "The Ledger is not open.", unsent = true)
        // `aborting` is cleared only by a fresh open, so a close() queued
        // behind this exchange still interrupts it.

        // Payload stream: length (BE u16) then the APDU, cut in 59-byte blocks.
        val data = ByteArray(2 + apdu.size)
        data[0] = ((apdu.size shr 8) and 0xFF).toByte()
        data[1] = (apdu.size and 0xFF).toByte()
        System.arraycopy(apdu, 0, data, 2, apdu.size)
        val block = PACKET - 5
        var offset = 0
        var seq = 0
        while (offset < data.size) {
            val packet = ByteArray(PACKET)
            header(packet, seq)
            val n = minOf(block, data.size - offset)
            System.arraycopy(data, offset, packet, 5, n)
            val wrote = conn.bulkTransfer(outEp, packet, PACKET, WRITE_TIMEOUT_MS)
            if (wrote != PACKET) {
                throw UsbError(failureCode(), "USB write to the Ledger failed ($wrote).", unsent = seq == 0)
            }
            offset += n
            seq++
        }

        val out = ByteArrayOutputStream()
        var expected = -1
        var readSeq = 0
        val deadline = SystemClock.elapsedRealtime() + EXCHANGE_TIMEOUT_MS
        val packet = ByteArray(PACKET)
        var hardFailures = 0
        while (expected < 0 || out.size() < expected) {
            if (aborting) {
                throw UsbError(if (detached) "DISCONNECTED" else "IO", "The Ledger connection was closed.")
            }
            if (SystemClock.elapsedRealtime() > deadline) {
                throw UsbError("TIMEOUT", "The Ledger did not answer.")
            }
            val started = SystemClock.elapsedRealtime()
            val n = conn.bulkTransfer(inEp, packet, PACKET, READ_SLICE_MS)
            if (n < 0) {
                // -1 is both "timed out" (the user has not confirmed yet) and
                // "failed"; a quick -1 is a failure.
                if (SystemClock.elapsedRealtime() - started < READ_SLICE_MS / 2) {
                    if (!stillAttached()) throw UsbError("DISCONNECTED", "The Ledger was unplugged.")
                    if (++hardFailures > 20) throw UsbError("IO", "USB read from the Ledger failed.")
                    SystemClock.sleep(10)
                } else {
                    hardFailures = 0
                }
                continue
            }
            hardFailures = 0
            if (n < 5) continue
            val channel = ((packet[0].toInt() and 0xFF) shl 8) or (packet[1].toInt() and 0xFF)
            val tag = packet[2].toInt() and 0xFF
            val index = ((packet[3].toInt() and 0xFF) shl 8) or (packet[4].toInt() and 0xFF)
            if (channel != CHANNEL || tag != TAG_APDU) {
                Log.w(TAG, "ignoring packet channel=0x${channel.toString(16)} tag=0x${tag.toString(16)}")
                continue
            }
            if (index != readSeq) throw UsbError("IO", "Ledger answer out of sequence ($index, wanted $readSeq).")
            var start = 5
            if (readSeq == 0) {
                if (n < 7) throw UsbError("IO", "Ledger answer too short.")
                expected = ((packet[5].toInt() and 0xFF) shl 8) or (packet[6].toInt() and 0xFF)
                start = 7
            }
            readSeq++
            val take = minOf(n - start, expected - out.size())
            if (take > 0) out.write(packet, start, take)
        }
        return out.toByteArray()
    }

    private fun header(packet: ByteArray, seq: Int) {
        packet[0] = ((CHANNEL shr 8) and 0xFF).toByte()
        packet[1] = (CHANNEL and 0xFF).toByte()
        packet[2] = TAG_APDU.toByte()
        packet[3] = ((seq shr 8) and 0xFF).toByte()
        packet[4] = (seq and 0xFF).toByte()
    }
}
