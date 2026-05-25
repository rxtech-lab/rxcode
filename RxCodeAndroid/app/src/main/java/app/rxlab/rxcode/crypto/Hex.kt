package app.rxlab.rxcode.crypto

object Hex {
    private val HEX = "0123456789abcdef".toCharArray()

    fun encode(bytes: ByteArray): String {
        val out = CharArray(bytes.size * 2)
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xFF
            out[i * 2] = HEX[v ushr 4]
            out[i * 2 + 1] = HEX[v and 0x0F]
        }
        return String(out)
    }

    fun decode(hex: String): ByteArray? {
        val trimmed = hex.trim()
        if (trimmed.length % 2 != 0) return null
        val out = ByteArray(trimmed.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(trimmed[i * 2], 16)
            val lo = Character.digit(trimmed[i * 2 + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }
}
