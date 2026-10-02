package com.floatclock.app.timesync

import android.os.SystemClock
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * SNTP 客户端（RFC 5905 48 字文报文，UDP 123）。
 * 完整 NTP 时延/偏移公式（非 HTTP 近似），是默认「北京时间」源的首选通道；
 * 网络拦截 UDP 123 时由上层回落 HTTP 秒沿法。
 */
object Sntp {

    private const val NTP_EPOCH_OFFSET = 2208988800L // 1900 → 1970 秒
    private const val TIMEOUT_MS = 2500

    class Sample(val offsetMs: Double, val delayMs: Long)

    /** 单次探测；失败（超时/被拦/报文异常）返回 null */
    fun probe(host: String): Sample? = runCatching {
        val t0Mono = SystemClock.elapsedRealtime()
        val t0Wall = System.currentTimeMillis()
        DatagramSocket().use { sock ->
            sock.soTimeout = TIMEOUT_MS
            val addr = InetAddress.getByName(host)
            val req = ByteArray(48)
            req[0] = 0x1B // LI=0 VN=3 Mode=3(client)
            sock.send(DatagramPacket(req, req.size, addr, 123))
            val buf = ByteArray(48)
            val pkt = DatagramPacket(buf, 48)
            sock.receive(pkt)
            val t1Mono = SystemClock.elapsedRealtime()

            if (pkt.length < 48) return@runCatching null
            val mode = buf[0].toInt() and 0x07
            val stratum = buf[1].toInt() and 0xFF
            if (mode != 4 && mode != 5) return@runCatching null // 应答必须是 server 模式
            if (stratum == 0) return@runCatching null           // Kiss-o'-Death 拒绝服务

            val t2 = ntpMs(buf, 32) // 服务器收到请求的时刻
            val t3 = ntpMs(buf, 40) // 服务器发出应答的时刻
            if (t2 <= 0 || t3 <= 0) return@runCatching null

            // NTP 公式 θ=((T2−T1)+(T3−T4))/2 的等价实现：
            // 服务器中点 − 本地中点；本地中点由「墙钟基点 + 单调差值」推出，防同步期间改时间
            val rtt = t1Mono - t0Mono
            val wallMid = t0Wall + rtt / 2.0
            val serverMid = (t2 + t3) / 2.0
            Sample(serverMid - wallMid, rtt)
        }
    }.getOrNull()

    /** NTP 64 位时间戳（32 位秒 + 32 位小数）→ Unix 毫秒；2020~2035 之外视为异常 */
    private fun ntpMs(b: ByteArray, off: Int): Long {
        val sec = u32(b, off)
        if (sec == 0L) return -1L
        val frac = u32(b, off + 4)
        val unix = (sec - NTP_EPOCH_OFFSET) * 1000 + frac * 1000 / 4_294_967_296L
        return if (unix < 1_577_836_800_000L || unix > 2_051_224_000_000L) -1L else unix
    }

    private fun u32(b: ByteArray, off: Int): Long =
        ((b[off].toLong() and 0xFF) shl 24) or ((b[off + 1].toLong() and 0xFF) shl 16) or
            ((b[off + 2].toLong() and 0xFF) shl 8) or (b[off + 3].toLong() and 0xFF)
}
