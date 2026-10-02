package com.floatclock.app

import android.app.Application
import com.floatclock.app.service.TimerService

class FloatClockApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppState.init(this)
        TimerService.createChannels(this)
    }
}
