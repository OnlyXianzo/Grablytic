package com.theonly.grablytic

import android.content.Intent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SEC-005: the receiver's "guard" was an action comparison that the manifest
 * comment presented as spoof resistance. The real guard is the framework's
 * protected-broadcast list; this test keeps the allowlist from quietly
 * widening, which is the only way the comment could become false again.
 *
 * `Intent.ACTION_*` are compile-time String constants, so this runs as a plain
 * JVM test — no Robolectric, no Context.
 */
class BootReceiverTest {

    @Test
    fun `boot completed triggers the sweep`() {
        assertTrue(BootReceiver.isSweepAction(Intent.ACTION_BOOT_COMPLETED))
    }

    @Test
    fun `an app update triggers the sweep`() {
        assertTrue(BootReceiver.isSweepAction(Intent.ACTION_MY_PACKAGE_REPLACED))
    }

    @Test
    fun `a missing action is ignored`() {
        assertFalse(BootReceiver.isSweepAction(null))
    }

    @Test
    fun `ordinary system broadcasts are ignored`() {
        listOf(
            Intent.ACTION_TIME_TICK,
            Intent.ACTION_SCREEN_ON,
            Intent.ACTION_POWER_CONNECTED,
            Intent.ACTION_USER_PRESENT,
        ).forEach { assertFalse(it, BootReceiver.isSweepAction(it)) }
    }

    @Test
    fun `an app-private action is ignored`() {
        assertFalse(BootReceiver.isSweepAction("com.theonly.grablytic.SWEEP"))
    }
}
