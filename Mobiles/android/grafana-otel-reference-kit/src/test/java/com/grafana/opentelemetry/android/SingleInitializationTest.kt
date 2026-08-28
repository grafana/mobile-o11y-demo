package com.grafana.opentelemetry.android

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class SingleInitializationTest {
    @Test
    fun `returns the first successful value`() {
        val initialization = SingleInitialization<Any>()
        val expected = Any()
        val calls = AtomicInteger()

        val first = initialization.getOrInitialize {
            calls.incrementAndGet()
            expected
        }
        val second = initialization.getOrInitialize {
            calls.incrementAndGet()
            Any()
        }

        assertSame(expected, first)
        assertSame(expected, second)
        assertSame(expected, initialization.getOrNull())
        assertEquals(1, calls.get())
    }

    @Test
    fun `does not retry after a failed initialization`() {
        val initialization = SingleInitialization<String>()
        val calls = AtomicInteger()

        assertThrows(IllegalStateException::class.java) {
            initialization.getOrInitialize {
                calls.incrementAndGet()
                error("failed")
            }
        }

        assertNull(initialization.getOrNull())
        val retry = assertThrows(IllegalStateException::class.java) {
            initialization.getOrInitialize {
                calls.incrementAndGet()
                "ready"
            }
        }
        assertEquals("Initialization previously failed; restart the process before retrying", retry.message)
        assertEquals("failed", retry.cause?.message)
        assertEquals(1, calls.get())
    }

    @Test
    fun `rejects reentrant initialization and remembers the failure`() {
        val initialization = SingleInitialization<String>()

        assertThrows(IllegalStateException::class.java) {
            initialization.getOrInitialize {
                initialization.getOrInitialize { "nested" }
            }
        }

        assertThrows(IllegalStateException::class.java) {
            initialization.getOrInitialize { "ready" }
        }
    }

    @Test
    fun `serializes concurrent initialization`() {
        val initialization = SingleInitialization<Any>()
        val expected = Any()
        val calls = AtomicInteger()
        val entered = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val first = executor.submit<Any> {
                initialization.getOrInitialize {
                    calls.incrementAndGet()
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                    expected
                }
            }
            check(entered.await(5, TimeUnit.SECONDS))
            val second = executor.submit<Any> {
                secondStarted.countDown()
                initialization.getOrInitialize {
                    calls.incrementAndGet()
                    Any()
                }
            }
            check(secondStarted.await(5, TimeUnit.SECONDS))

            assertThrows(TimeoutException::class.java) {
                second.get(100, TimeUnit.MILLISECONDS)
            }

            release.countDown()

            assertSame(expected, first.get(5, TimeUnit.SECONDS))
            assertSame(expected, second.get(5, TimeUnit.SECONDS))
            assertEquals(1, calls.get())
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }
}
