package com.poopbox2.poopbox2

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 사고 후 응답이 없을 때 보호자에게 긴급 문자를 자동으로 보낸다.
// (lib/services/emergency_dispatch_service.dart 에서 호출)
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daebyeonbox/emergency_sms")
            .setMethodCallHandler { call, result ->
                if (call.method != "send") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val phone = call.argument<String>("phone")
                val message = call.argument<String>("message")
                if (phone.isNullOrBlank() || message.isNullOrBlank()) {
                    result.error("bad_args", "phone and message are required", null)
                    return@setMethodCallHandler
                }
                val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                    checkSelfPermission(Manifest.permission.SEND_SMS) ==
                    PackageManager.PERMISSION_GRANTED
                if (!granted) {
                    result.error("no_permission", "SEND_SMS is not granted", null)
                    return@setMethodCallHandler
                }
                try {
                    val sms: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        getSystemService(SmsManager::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        SmsManager.getDefault()
                    }
                    // 한글 긴 문자는 여러 개로 나눠 보낸다
                    val parts = sms.divideMessage(message)
                    sms.sendMultipartTextMessage(phone, null, parts, null, null)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("send_failed", e.message, null)
                }
            }
    }
}
