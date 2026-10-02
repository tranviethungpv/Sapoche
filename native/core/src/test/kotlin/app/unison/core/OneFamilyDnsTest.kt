package app.unison.core

import okhttp3.Dns
import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertEquals

class OneFamilyDnsTest {
    private val v4 = InetAddress.getByAddress("host", byteArrayOf(142.toByte(), 250.toByte(), 1, 1))
    private val v6 = InetAddress.getByAddress("host", ByteArray(16) { if (it == 0) 0x24 else it.toByte() })

    private fun dns(vararg addresses: InetAddress) = OneFamilyDns(Dns { addresses.toList() })

    @Test
    fun `a host with both families is only reached over IPv4`() {
        assertEquals(listOf(v4), dns(v6, v4).lookup("host"))
    }

    @Test
    fun `a host with only IPv6 is still reached`() {
        assertEquals(listOf(v6), dns(v6).lookup("host"))
    }
}
