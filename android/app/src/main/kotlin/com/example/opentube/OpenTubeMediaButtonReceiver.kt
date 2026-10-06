package com.example.opentube

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.view.KeyEvent

class OpenTubeMediaButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_MEDIA_BUTTON == intent.action) {
            val event = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
            if (event != null && event.action == KeyEvent.ACTION_DOWN) {
                // Перенаправляємо подію в MainActivity через інтенд
                val serviceIntent = Intent(context, MainActivity::class.java).apply {
                    action = "com.opentube.MEDIA_BUTTON_EVENT"
                    putExtra("keyCode", event.keyCode)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }
                context.startActivity(serviceIntent)
            }
        }
    }
}