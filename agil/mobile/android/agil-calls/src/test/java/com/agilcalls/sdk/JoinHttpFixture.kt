package com.agilcalls.sdk

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.Collections

/** One fixed HTTP response for join-client tests, over a real loopback socket. */
internal class JoinHttpFixture(status: Int, body: String, location: String?) : AutoCloseable {
    private val server = ServerSocket().apply { bind(InetSocketAddress("127.0.0.1", 0)) }
    val requests: List<String> get() = received
    private val received = Collections.synchronizedList(ArrayList<String>())
    private val responseBody = body.toByteArray(Charsets.UTF_8)
    private val responseHeaders = buildString {
        append("HTTP/1.1 $status Test\r\n")
        append("Content-Type: application/json\r\nContent-Length: ${responseBody.size}\r\nConnection: close\r\n")
        if (location != null) append("Location: $location\r\n")
        append("\r\n")
    }.toByteArray(Charsets.US_ASCII)
    private val worker = Thread({ serve() }, "agil-join-http-fixture").apply {
        isDaemon = true
        start()
    }

    fun url() = "http://127.0.0.1:${server.localPort}"

    override fun close() {
        server.close()
        worker.join(5_000)
    }

    private fun serve() {
        try {
            while (!server.isClosed) server.accept().use { socket ->
                socket.soTimeout = 4_000
                val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
                val request = input.readHeaderLine().split(' ')
                var length = 0
                while (true) {
                    val header = input.readHeaderLine()
                    if (header.isEmpty()) break
                    if (header.startsWith("Content-Length:", ignoreCase = true)) {
                        length = header.substringAfter(':').trim().toInt()
                    }
                }
                val requestBody = ByteArray(length).also(input::readFully)
                received.add("${request[0]} ${request[1]} ${requestBody.toString(Charsets.UTF_8)}")
                socket.getOutputStream().apply {
                    write(responseHeaders)
                    write(responseBody)
                    flush()
                }
            }
        } catch (error: SocketException) {
            if (!server.isClosed) throw error
        }
    }

    private fun DataInputStream.readHeaderLine(): String {
        val line = ByteArrayOutputStream()
        while (true) {
            val byte = readUnsignedByte()
            if (byte == '\n'.code) return line.toString("US-ASCII").trimEnd('\r')
            line.write(byte)
        }
    }
}
