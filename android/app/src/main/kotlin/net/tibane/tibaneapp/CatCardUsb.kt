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
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * The CatCard's CCID smart-card reader, driven directly over USB host.
 *
 * Android has no system smart-card service, so this speaks the CCID bulk
 * protocol itself (USB CCID rev 1.1 §6): power the card on, then one
 * `PC_to_RDR_XfrBlock` per APDU answered by one `RDR_to_PC_DataBlock`. The
 * device is a composite with a vendor HID interface and the reader; only the
 * reader (class 0x0B) is claimed. Every protocol byte above the APDU is built
 * in Dart; this is the transport and nothing else.
 */
class CatCardUsb(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "CatCardUsb"
        const val METHOD_CHANNEL = "net.tibane.tibaneapp/catcard"
        const val EVENT_CHANNEL = "net.tibane.tibaneapp/catcard/readers"

        /** Karpeles Lab's vendor id and the CatCard firmware's product id. */
        const val VENDOR_ID = 0x39F2
        const val PRODUCT_ID = 0x0401
        const val CCID_CLASS = 0x0B

        private const val ACTION_PERMISSION = "net.tibane.tibaneapp.CATCARD_USB_PERMISSION"

        /** The reader's `dwMaxCCIDMessageLength`. */
        private const val MESSAGE_MAX = 1088
        private const val HEADER = 10
        private const val PACKET = 64
        private const val WRITE_TIMEOUT_MS = 5_000
        private const val READ_TIMEOUT_MS = 15_000

        private const val PC_TO_RDR_ICC_POWER_ON = 0x62
        private const val PC_TO_RDR_ICC_POWER_OFF = 0x63
        private const val PC_TO_RDR_XFR_BLOCK = 0x6F
        private const val RDR_TO_PC_DATA_BLOCK = 0x80
        private const val STATUS_COMMAND_FAILED = 0x40
        private const val STATUS_TIME_EXTENSION = 0x80
    }

    private val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private var connection: UsbDeviceConnection? = null
    private var iface: UsbInterface? = null
    private var endpointIn: UsbEndpoint? = null
    private var endpointOut: UsbEndpoint? = null
    private var seq = 0

    private var sink: EventChannel.EventSink? = null
    private var hotplug: BroadcastReceiver? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        close()
        unregisterHotplug()
        io.shutdown()
    }

    // ---- discovery ----------------------------------------------------------------

    private fun ccidInterface(device: UsbDevice): UsbInterface? {
        for (i in 0 until device.interfaceCount) {
            val candidate = device.getInterface(i)
            if (candidate.interfaceClass == CCID_CLASS) return candidate
        }
        return null
    }

    private fun catCards(): List<UsbDevice> = manager.deviceList.values.filter {
        it.vendorId == VENDOR_ID && it.productId == PRODUCT_ID && ccidInterface(it) != null
    }

    private fun readerNames(): List<String> = catCards().map { it.deviceName }

    // ---- method channel -----------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
            )
            "listReaders" -> result.success(readerNames())
            "open" -> open(call.argument<String>("name"), result)
            "transmit" -> {
                val apdu = call.argument<ByteArray>("apdu")
                if (apdu == null) {
                    result.error("BAD_ARGS", "transmit needs an APDU.", null)
                    return
                }
                io.execute {
                    try {
                        val reply = xfrBlock(apdu)
                        main.post { result.success(reply) }
                    } catch (e: Exception) {
                        Log.w(TAG, "transmit failed", e)
                        main.post { result.error("IO", e.message, null) }
                    }
                }
            }
            "close" -> {
                io.execute {
                    close()
                    main.post { result.success(null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun open(name: String?, result: MethodChannel.Result) {
        val device = catCards().firstOrNull { name == null || it.deviceName == name }
        if (device == null) {
            result.error("NO_DEVICE", "No CatCard is plugged in.", null)
            return
        }
        if (manager.hasPermission(device)) {
            openGranted(device, result)
            return
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != ACTION_PERMISSION) return
                try {
                    context.unregisterReceiver(this)
                } catch (_: IllegalArgumentException) {
                }
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (granted) {
                    openGranted(device, result)
                } else {
                    result.error("PERMISSION_DENIED", "USB access to the CatCard was not allowed.", null)
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
        manager.requestPermission(device, PendingIntent.getBroadcast(context, 0, intent, flags))
    }

    private fun openGranted(device: UsbDevice, result: MethodChannel.Result) {
        io.execute {
            try {
                close()
                val candidate = ccidInterface(device) ?: throw IOException("The CatCard has no reader interface.")
                val conn = manager.openDevice(device) ?: throw IOException("Could not open the CatCard.")
                if (!conn.claimInterface(candidate, true)) {
                    conn.close()
                    throw IOException("Could not claim the CatCard's reader.")
                }
                var inEp: UsbEndpoint? = null
                var outEp: UsbEndpoint? = null
                for (k in 0 until candidate.endpointCount) {
                    val ep = candidate.getEndpoint(k)
                    if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                    if (ep.direction == UsbConstants.USB_DIR_IN) inEp = ep else outEp = ep
                }
                if (inEp == null || outEp == null) {
                    conn.releaseInterface(candidate)
                    conn.close()
                    throw IOException("The CatCard's reader has no bulk endpoints.")
                }
                connection = conn
                iface = candidate
                endpointIn = inEp
                endpointOut = outEp
                seq = 0
                // IccPowerOn: bPowerSelect 0 (automatic), two reserved bytes. The
                // answer is the ATR.
                val atr = command(PC_TO_RDR_ICC_POWER_ON, byteArrayOf(0, 0, 0), ByteArray(0))
                main.post { result.success(mapOf("name" to device.deviceName, "atr" to atr)) }
            } catch (e: Exception) {
                Log.w(TAG, "open failed", e)
                close()
                main.post { result.error("IO", e.message, null) }
            }
        }
    }

    private fun close() {
        val conn = connection ?: return
        try {
            if (endpointOut != null && endpointIn != null) {
                command(PC_TO_RDR_ICC_POWER_OFF, byteArrayOf(0, 0, 0), ByteArray(0), expectDataBlock = false)
            }
        } catch (_: Exception) {
        }
        try {
            iface?.let { conn.releaseInterface(it) }
        } catch (_: Exception) {
        }
        try {
            conn.close()
        } catch (_: Exception) {
        }
        connection = null
        iface = null
        endpointIn = null
        endpointOut = null
    }

    // ---- CCID ---------------------------------------------------------------------

    /** `PC_to_RDR_XfrBlock`: bBWI 0, wLevelParameter 0 (a whole APDU in one command). */
    private fun xfrBlock(apdu: ByteArray): ByteArray =
        command(PC_TO_RDR_XFR_BLOCK, byteArrayOf(0, 0, 0), apdu)

    /**
     * One CCID command and the data of its answer. The header is ten bytes:
     * `bMessageType, dwLength (LE), bSlot, bSeq, three message-specific bytes`;
     * the answer's three are `bStatus, bError, bChainParameter`.
     */
    private fun command(
        type: Int,
        params: ByteArray,
        data: ByteArray,
        expectDataBlock: Boolean = true,
    ): ByteArray {
        val conn = connection ?: throw IOException("The CatCard is not open.")
        val outEp = endpointOut ?: throw IOException("The CatCard is not open.")
        val inEp = endpointIn ?: throw IOException("The CatCard is not open.")
        if (HEADER + data.size > MESSAGE_MAX) {
            throw IOException("CCID command over $MESSAGE_MAX bytes")
        }
        val message = ByteArray(HEADER + data.size)
        message[0] = type.toByte()
        message[1] = (data.size and 0xFF).toByte()
        message[2] = ((data.size shr 8) and 0xFF).toByte()
        message[3] = ((data.size shr 16) and 0xFF).toByte()
        message[4] = ((data.size shr 24) and 0xFF).toByte()
        message[5] = 0 // slot
        val mySeq = seq
        message[6] = mySeq.toByte()
        seq = (seq + 1) and 0xFF
        System.arraycopy(params, 0, message, 7, 3)
        System.arraycopy(data, 0, message, HEADER, data.size)

        val wrote = conn.bulkTransfer(outEp, message, message.size, WRITE_TIMEOUT_MS)
        if (wrote != message.size) throw IOException("USB write to the CatCard failed ($wrote).")

        while (true) {
            val reply = readMessage(conn, inEp)
            if ((reply[6].toInt() and 0xFF) != mySeq) {
                throw IOException("CCID reply out of sequence.")
            }
            val status = reply[7].toInt() and 0xFF
            val error = reply[8].toInt() and 0xFF
            if ((status and 0xC0) == STATUS_TIME_EXTENSION) continue // the card asked for time
            if ((status and STATUS_COMMAND_FAILED) != 0) {
                throw IOException("The CatCard's reader refused the command (error 0x${error.toString(16)}).")
            }
            val kind = reply[0].toInt() and 0xFF
            if (expectDataBlock && kind != RDR_TO_PC_DATA_BLOCK) {
                throw IOException("Unexpected CCID reply 0x${kind.toString(16)}.")
            }
            return reply.copyOfRange(HEADER, reply.size)
        }
    }

    /** One whole `RDR_to_PC_*` message, read a packet at a time up to its `dwLength`. */
    private fun readMessage(conn: UsbDeviceConnection, inEp: UsbEndpoint): ByteArray {
        val packet = ByteArray(PACKET)
        val out = ByteArrayOutputStream()
        var total = -1
        var emptyReads = 0
        while (total < 0 || out.size() < total) {
            val n = conn.bulkTransfer(inEp, packet, PACKET, READ_TIMEOUT_MS)
            if (n < 0) throw IOException("The CatCard did not answer.")
            if (n == 0) {
                if (++emptyReads > 8) throw IOException("The CatCard sent nothing.")
                continue
            }
            out.write(packet, 0, n)
            if (total < 0 && out.size() >= HEADER) {
                val b = out.toByteArray()
                val len = (b[1].toInt() and 0xFF) or
                    ((b[2].toInt() and 0xFF) shl 8) or
                    ((b[3].toInt() and 0xFF) shl 16) or
                    ((b[4].toInt() and 0xFF) shl 24)
                if (len < 0 || len > MESSAGE_MAX) throw IOException("CCID reply length $len is out of range.")
                total = HEADER + len
            }
        }
        val bytes = out.toByteArray()
        return if (bytes.size > total) bytes.copyOfRange(0, total) else bytes
    }

    // ---- hot-plug events ----------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                sink?.success(readerNames())
            }
        }
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        hotplug = receiver
        events.success(readerNames())
    }

    override fun onCancel(arguments: Any?) {
        unregisterHotplug()
        sink = null
    }

    private fun unregisterHotplug() {
        hotplug?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        hotplug = null
    }
}
