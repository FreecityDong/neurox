package com.neurox.neurox

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.*
import android.provider.Settings
import io.flutter.plugin.common.*
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** KSEEG102 F-version BLE transport. Every GATT operation is serialized on main. */
@SuppressLint("MissingPermission")
class EegBleBridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val PERMISSION_REQUEST = 4101
        private const val ENABLE_REQUEST = 4102
        private const val EXPORT_REQUEST = 4103
        private fun uuid(id: String) = UUID.fromString("8653$id-43e6-47b7-9cb0-5fc21d4ae340")
        val SERVICE: UUID = uuid("000a")
        val RAW: UUID = uuid("000b")
        val WRITE: UUID = uuid("000c")
        val FEATURE: UUID = uuid("000d")
        val FREQUENCY: UUID = uuid("000e")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val methods = MethodChannel(messenger, "neurox/eeg/methods")
    private val events = EventChannel(messenger, "neurox/eeg/events")
    private val manager = activity.getSystemService(BluetoothManager::class.java)
    private val adapter get() = manager?.adapter
    private var sink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private var enableResult: MethodChannel.Result? = null
    private var exportResult: MethodChannel.Result? = null
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var scanTimeout: Runnable? = null
    private var gatt: BluetoothGatt? = null
    private var session = 0
    private var phase = "disconnected"
    private var deviceAddress: String? = null
    private var mtu = 23
    private var waiting = ""
    private var stepTimeout: Runnable? = null
    private val subscriptions = ArrayDeque<BluetoothGattCharacteristic>()
    private var control: BluetoothGattCharacteristic? = null
    private var commandIndex = 0
    private var disposed = false
    private var recording = false
    private var lastFile: File? = null
    // Only accessed on the single IO executor, preserving frame and close order.
    private var writer: BufferedWriter? = null
    private var sequence = 0L
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                if (state != BluetoothAdapter.STATE_ON) disconnect("蓝牙已关闭，采集已停止")
                emit("adapter", access())
            }
        }
    }
    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(
            receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED
        ) else activity.registerReceiver(receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        emit("adapter", access())
    }
    override fun onCancel(arguments: Any?) {
        sink = null
        disconnect("页面已关闭")
    }
    private fun emit(type: String, fields: Map<String, Any?> = emptyMap()) {
        val event = fields + mapOf("type" to type)
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (!disposed) sink?.success(event)
        } else main.post { if (!disposed) sink?.success(event) }
    }
    private fun state(value: String, message: String) {
        phase = value
        emit("connection", mapOf("state" to value, "message" to message,
            "address" to deviceAddress, "mtu" to mtu, "session" to session))
    }
    private fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31)
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun access(): Map<String, Any?> {
        val granted = requiredPermissions().all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        val location = activity.getSystemService(LocationManager::class.java)
        val locationEnabled = if (Build.VERSION.SDK_INT >= 28) location.isLocationEnabled else
            Settings.Secure.getInt(activity.contentResolver, Settings.Secure.LOCATION_MODE, 0) != 0
        val asked = activity.getPreferences(Context.MODE_PRIVATE).getBoolean("blePermissionRequested", false)
        val permanentlyDenied = !granted && asked && requiredPermissions().any {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED && !activity.shouldShowRequestPermissionRationale(it)
        }
        val enabled = try { granted && adapter?.isEnabled == true } catch (_: SecurityException) { false }
        return mapOf("platform" to "android", "supported" to (adapter != null && activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)),
            "enabled" to enabled, "permissionsGranted" to granted, "permanentlyDenied" to permanentlyDenied,
            "locationRequired" to (Build.VERSION.SDK_INT < 31), "locationEnabled" to locationEnabled)
    }
    private fun requireAccess() {
        val a = access()
        check(a["supported"] == true) { "此设备不支持 BLE 蓝牙" }
        check(a["permissionsGranted"] == true) { "请先允许蓝牙权限" }
        check(a["enabled"] == true) { "请先开启手机蓝牙" }
        check(a["locationRequired"] != true || a["locationEnabled"] == true) { "Android 11 及以下需要开启定位服务才能扫描 BLE" }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "access" -> result.success(access())
                "requestAccess" -> {
                    if (access()["permissionsGranted"] == true) result.success(access()) else {
                        check(permissionResult == null) { "正在等待权限确认" }
                        permissionResult = result
                        activity.getPreferences(Context.MODE_PRIVATE).edit().putBoolean("blePermissionRequested", true).apply()
                        activity.requestPermissions(requiredPermissions(), PERMISSION_REQUEST)
                    }
                }
                "enableBluetooth" -> {
                    check(access()["permissionsGranted"] == true) { "请先允许蓝牙权限" }
                    if (adapter?.isEnabled == true) result.success(access()) else {
                        check(enableResult == null) { "正在等待开启蓝牙" }
                        enableResult = result
                        activity.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), ENABLE_REQUEST)
                    }
                }
                "openSettings" -> {
                    activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        android.net.Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                "openLocationSettings" -> { activity.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)); result.success(null) }
                "scan" -> { requireAccess(); startScan(); result.success(null) }
                "stopScan" -> { stopScan(); result.success(null) }
                "connect" -> {
                    requireAccess()
                    val address = call.argument<String>("address") ?: error("缺少设备地址")
                    check(BluetoothAdapter.checkBluetoothAddress(address)) { "蓝牙地址无效" }
                    connect(address); result.success(null)
                }
                "disconnect" -> { disconnect("已主动断开，采集已停止"); result.success(null) }
                "startRecording" -> startRecording(result)
                "stopRecording" -> stopRecording(result)
                "recordAlgorithm" -> {
                    val fields = call.arguments as? Map<*, *>
                    if (recording && fields != null &&
                        (fields["session"] as? Number)?.toInt() == session && fields["address"] == deviceAddress) {
                        sequence++
                        val record = JSONObject(fields)
                            .put("source", "host/Dart port of KSEEG102_Python_Mac")
                            .put("platform", "android")
                            .put("sequence", sequence).toString()
                        io.execute {
                            try { writer?.apply { write(record); newLine() } }
                            catch (e: Exception) { main.post { stopRecording(null); emit("error", mapOf("message" to "算法记录失败：${e.message}")) } }
                        }
                    }
                    result.success(null)
                }
                "exportRecording" -> {
                    check(!recording) { "请先停止记录" }
                    val file = lastFile ?: error("还没有可导出的记录")
                    check(exportResult == null) { "正在导出" }
                    exportResult = result
                    activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE); type = "application/x-ndjson"
                        putExtra(Intent.EXTRA_TITLE, file.name)
                    }, EXPORT_REQUEST)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            if (permissionResult === result) permissionResult = null
            if (enableResult === result) enableResult = null
            if (exportResult === result) exportResult = null
            result.error("BLE_ERROR", e.message ?: e.javaClass.simpleName, null)
        }
    }
    fun onPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionResult?.success(access()); permissionResult = null
        emit("adapter", access()); return true
    }
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == ENABLE_REQUEST) {
            enableResult?.success(access()); enableResult = null; emit("adapter", access()); return true
        }
        if (requestCode != EXPORT_REQUEST) return false
        val result = exportResult; exportResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result?.success(false); return true }
        val file = lastFile
        io.execute {
            try {
                check(file != null && file.exists()) { "记录文件不存在" }
                activity.contentResolver.openOutputStream(uri)?.use { output -> file.inputStream().use { it.copyTo(output) } }
                    ?: error("无法打开导出位置")
                main.post { result?.success(true) }
            } catch (e: Exception) { main.post { result?.error("EXPORT_FAILED", e.message, null) } }
        }
        return true
    }

    private fun startScan() {
        check(gatt == null) { "请先断开当前设备再搜索" }
        stopScan()
        val scan = adapter?.bluetoothLeScanner ?: error("无法使用蓝牙扫描器")
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                main.post {
                    if (scanCallback !== this) return@post
                    val record = result.scanRecord
                    val name = record?.deviceName ?: try { result.device.name } catch (_: SecurityException) { null }
                    emit("device", mapOf("address" to result.device.address, "name" to name.orEmpty(),
                        "rssi" to result.rssi, "advertisesService" to (record?.serviceUuids?.any { it.uuid == SERVICE } == true)))
                }
            }
            override fun onScanFailed(errorCode: Int) {
                main.post {
                    if (scanCallback !== this) return@post
                    stopScan(); emit("error", mapOf("message" to "蓝牙扫描失败（$errorCode），请稍后重试"))
                }
            }
        }
        scanner = scan; scanCallback = callback
        try {
            // Do not filter by name/service: some KSEEG firmware advertises neither.
            scan.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
        } catch (e: Exception) { scanner = null; scanCallback = null; throw e }
        emit("scan", mapOf("scanning" to true))
        scanTimeout = Runnable { stopScan() }.also { main.postDelayed(it, 10000) }
    }
    private fun stopScan() {
        scanTimeout?.let { main.removeCallbacks(it) }; scanTimeout = null
        val callback = scanCallback; scanCallback = null
        try { if (callback != null) scanner?.stopScan(callback) } catch (_: Exception) { }
        scanner = null
        emit("scan", mapOf("scanning" to false))
    }
    private fun connect(address: String) {
        stopScan()
        disconnect("准备连接")
        session++; deviceAddress = address; mtu = 23; sequence = 0
        state("connecting", "正在连接设备…")
        gatt = adapter!!.getRemoteDevice(address).connectGatt(activity, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null) { fail("无法创建蓝牙连接"); return }
        armTimeout("connect", "设备连接超时，请检查电源并关闭其他占用设备的 App", 20000)
    }
    private fun armTimeout(step: String, message: String, delay: Long = 10000) {
        clearTimeout(); waiting = step
        val expected = gatt
        stepTimeout = Runnable { if (gatt === expected && waiting == step) fail(message) }
            .also { main.postDelayed(it, delay) }
    }
    private fun clearTimeout() { stepTimeout?.let { main.removeCallbacks(it) }; stepTimeout = null; waiting = "" }
    private fun fail(message: String) { disconnect(message); state("error", message) }
    private fun disconnect(message: String) {
        stopScan(); clearTimeout(); subscriptions.clear(); control = null
        val old = gatt; gatt = null
        if (old != null) {
            try { old.disconnect() } catch (_: Exception) { }
            try { old.close() } catch (_: Exception) { }
        }
        stopRecording(null)
        state("disconnected", message)
    }
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(client: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (gatt !== client) return@post
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    disconnect(if (status == 0) "设备已断开，采集已停止" else "蓝牙连接失败（GATT $status），可重新连接")
                    return@post
                }
                if (newState == BluetoothProfile.STATE_CONNECTED && phase == "connecting") {
                    try {
                        state("discovering", "正在发现 EEG 服务…")
                        armTimeout("services", "发现服务超时")
                        if (!client.discoverServices()) fail("无法开始发现服务")
                    } catch (e: Exception) { fail(e.message ?: "发现服务失败") }
                }
            }
        }
        override fun onServicesDiscovered(client: BluetoothGatt, status: Int) {
            main.post {
                if (gatt !== client || waiting != "services") return@post
                try {
                    if (status != BluetoothGatt.GATT_SUCCESS) { fail("发现服务失败（$status）"); return@post }
                    val service = client.getService(SERVICE)
                    if (service?.getCharacteristic(RAW) == null) { fail("未找到 KSEEG102 F-version 原始脑电服务，请核对设备和固件"); return@post }
                    control = service.getCharacteristic(WRITE)
                    for (id in listOf(RAW, FREQUENCY, FEATURE)) {
                        val characteristic = service.getCharacteristic(id)
                        if (characteristic != null) subscriptions.addLast(characteristic)
                        else emit("log", mapOf("message" to "设备未提供特征 $id"))
                    }
                    state("configuring", "正在协商蓝牙数据长度…")
                    armTimeout("mtu", "MTU 协商超时，请重新连接")
                    if (!client.requestMtu(247)) fail("无法协商 MTU，完整原始通知需要至少 72 字节 MTU")
                } catch (e: Exception) { fail(e.message ?: "设备服务配置失败") }
            }
        }
        override fun onMtuChanged(client: BluetoothGatt, value: Int, status: Int) {
            main.post {
                if (gatt !== client || waiting != "mtu") return@post
                if (status != BluetoothGatt.GATT_SUCCESS || value < 72) { fail("MTU 不足（$value），无法完整接收 69 字节原始脑电通知"); return@post }
                mtu = value; clearTimeout(); subscribeNext()
            }
        }
        override fun onDescriptorWrite(client: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post {
                if (gatt !== client || waiting != "subscribe:${descriptor.characteristic.uuid}") return@post
                if (status != BluetoothGatt.GATT_SUCCESS) { fail("通知订阅失败（$status）"); return@post }
                clearTimeout(); subscriptions.removeFirst(); subscribeNext()
            }
        }
        override fun onCharacteristicWrite(client: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            main.post {
                if (gatt !== client || characteristic.uuid != WRITE || waiting != "command:$commandIndex") return@post
                if (status != BluetoothGatt.GATT_SUCCESS) { fail("初始化命令失败（$status）"); return@post }
                clearTimeout(); commandIndex++
                val expectedIndex = commandIndex
                main.postDelayed({
                    if (gatt === client && phase == "configuring" && waiting.isEmpty() && commandIndex == expectedIndex) writeNextCommand()
                }, if (expectedIndex == 1) 100L else 0L)
            }
        }
        override fun onCharacteristicChanged(client: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            notification(client, characteristic.uuid, value.copyOf(), System.currentTimeMillis())
        }
        @Deprecated("Compatibility for Android before API 33")
        override fun onCharacteristicChanged(client: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            notification(client, characteristic.uuid, characteristic.value?.copyOf() ?: return, System.currentTimeMillis())
        }
    }
    private fun subscribeNext() {
        val client = gatt ?: return
        val characteristic = subscriptions.firstOrNull()
        if (characteristic == null) { commandIndex = 0; writeNextCommand(); return }
        try {
            val notify = characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0
            val indicate = characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
            check(notify || indicate) { "特征不支持通知：${characteristic.uuid}" }
            check(client.setCharacteristicNotification(characteristic, true)) { "开启本地通知失败" }
            val descriptor = characteristic.getDescriptor(CCCD) ?: error("设备通知缺少 CCCD")
            val value = if (notify) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            state("configuring", "正在订阅脑电、频谱及设备指标…")
            armTimeout("subscribe:${characteristic.uuid}", "订阅通知超时")
            val ok = if (Build.VERSION.SDK_INT >= 33) client.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
                else { descriptor.value = value; client.writeDescriptor(descriptor) }
            check(ok) { "无法写入通知订阅设置" }
        } catch (e: Exception) { fail(e.message ?: "订阅失败") }
    }
    private fun writeNextCommand() {
        val client = gatt ?: return
        if (commandIndex >= 2) { state("ready", "已连接并订阅，等待真实脑电数据"); return }
        val characteristic = control
        if (characteristic == null) { fail("缺少初始化写入特征，无法完成设备配置"); return }
        try {
            val response = characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
            check(response || characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) { "设备控制特征不可写" }
            val kind = if (response) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            val bytes = byteArrayOf(if (commandIndex == 0) 0x35.toByte() else 0x45.toByte())
            armTimeout(if (response) "command:$commandIndex" else "noResponse:$commandIndex", "设备初始化超时")
            val ok = if (Build.VERSION.SDK_INT >= 33) client.writeCharacteristic(characteristic, bytes, kind) == BluetoothStatusCodes.SUCCESS
                else { characteristic.writeType = kind; characteristic.value = bytes; client.writeCharacteristic(characteristic) }
            check(ok) { "无法发送设备初始化命令" }
            if (!response) {
                // No-response writes have no peripheral acknowledgement. Pace them and
                // ignore write callbacks so a late callback cannot complete the next op.
                val index = commandIndex
                main.postDelayed({
                    if (gatt === client && waiting == "noResponse:$index") { clearTimeout(); commandIndex++; writeNextCommand() }
                }, 300)
            }
        } catch (e: Exception) { fail(e.message ?: "初始化失败") }
    }
    private fun notification(client: BluetoothGatt, uuid: UUID, bytes: ByteArray, receivedAt: Long) {
        main.post {
            if (gatt !== client || uuid !in listOf(RAW, FREQUENCY, FEATURE)) return@post
            sequence++
            val fields = mapOf("uuid" to uuid.toString(), "bytes" to bytes, "receivedAt" to receivedAt,
                "sequence" to sequence, "session" to session, "address" to deviceAddress)
            emit("packet", fields)
            if (recording) {
                val record = JSONObject(mapOf("uuid" to uuid.toString(), "hex" to bytes.joinToString("") { "%02x".format(it.toInt() and 255) },
                    "received_at" to java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }.format(java.util.Date(receivedAt)), "receivedAt" to receivedAt,
                    "sequence" to sequence, "session" to session, "source" to "KSEEG102 BLE", "address" to deviceAddress,
                    "protocol" to "KSEEG102-F-2.1", "init_commands" to listOf("35", "45"))).toString()
                io.execute {
                    try { writer?.apply { write(record); newLine() } }
                    catch (e: Exception) { main.post { stopRecording(null); emit("error", mapOf("message" to "记录失败：${e.message}")) } }
                }
            }
        }
    }
    private fun startRecording(result: MethodChannel.Result) {
        check(phase == "ready") { "请先完成设备连接" }
        check(!recording) { "已在记录中" }
        val file = File(activity.getExternalFilesDir(null) ?: activity.filesDir, "eeg-recordings/${System.currentTimeMillis()}.jsonl")
        val expectedGatt = gatt
        recording = true
        io.execute {
            try {
                file.parentFile?.mkdirs(); writer = file.bufferedWriter(); lastFile = file
                main.post {
                    if (gatt === expectedGatt && recording) {
                        emit("recording", mapOf("active" to true, "name" to file.name)); result.success(file.name)
                    } else result.error("CANCELLED", "连接已结束，记录已关闭", null)
                }
            } catch (e: Exception) { main.post { recording = false; result.error("RECORD_FAILED", e.message, null) } }
        }
    }
    private fun stopRecording(result: MethodChannel.Result?) {
        if (!recording) { result?.success(lastFile?.name); return }
        recording = false
        io.execute {
            try {
                writer?.close(); writer = null
                main.post { emit("recording", mapOf("active" to false, "name" to lastFile?.name)); result?.success(lastFile?.name) }
            } catch (e: Exception) {
                writer = null
                main.post { emit("error", mapOf("message" to "保存记录失败：${e.message}")); result?.error("RECORD_FAILED", e.message, null) }
            }
        }
    }
    fun onBackground() {
        if (gatt != null || scanCallback != null) disconnect("应用已进入后台，前台采集已停止；返回后可重新连接")
    }
    fun dispose() {
        disconnect("应用已关闭")
        permissionResult?.error("CLOSED", "页面已关闭", null); permissionResult = null
        enableResult?.error("CLOSED", "页面已关闭", null); enableResult = null
        exportResult?.error("CLOSED", "页面已关闭", null); exportResult = null
        disposed = true; sink = null
        methods.setMethodCallHandler(null); events.setStreamHandler(null)
        try { activity.unregisterReceiver(receiver) } catch (_: Exception) { }
        io.shutdown()
    }
}
