package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one-shot timeout fallback, Android side.
 *
 * Mirrors Swift `AICoachTimeoutFallbackTests`. The cross-platform contract is that both apps pick the
 * SAME fallback model for the same provider — a user switching phones should not get a different retry
 * — so these ids are asserted literally on both sides rather than derived.
 */
class AiCoachTimeoutFallbackTest {

    /** Every cloud provider names a fallback, or a timeout retries the same model and does nothing. */
    @Test
    fun cloudProvidersNameACheapestModel() {
        assertEquals("gpt-4.1-nano", AiProvider.OPENAI.cheapestModel)
        assertEquals("claude-haiku-4-5-20251001", AiProvider.ANTHROPIC.cheapestModel)
        assertEquals("gemini-flash-lite-latest", AiProvider.GEMINI.cheapestModel)
    }

    /**
     * Custom has none: it points at whatever server the user runs, so there is no basis for calling one
     * of its ids cheaper. The retry re-sends the same model in that case rather than inventing one.
     */
    @Test
    fun customHasNoCheapestModel() {
        assertNull(AiProvider.CUSTOM.cheapestModel)
    }

    /**
     * The fallback must be an id the provider actually serves — a typo turns every timeout into a
     * second, worse failure (model-not-found instead of a timeout).
     */
    @Test
    fun cheapestModelIsInTheProvidersOwnCatalogue() {
        for (provider in AiProvider.entries) {
            val cheapest = provider.cheapestModel ?: continue
            assertTrue(
                "${provider.name}'s cheapest model $cheapest is not in its own models list, " +
                    "so the fallback would request an id the picker never offers",
                provider.models.contains(cheapest),
            )
        }
    }

    /**
     * A timeout is its own type so the retry can recognise it without matching message text — which
     * would work in English and silently stop retrying in every other language the app ships.
     */
    @Test
    fun timeoutIsADistinctExceptionType() {
        val e: Exception = CoachTimeoutException("timed out")
        assertTrue("a timeout must be distinguishable by type", e is CoachTimeoutException)
        assertTrue("and still a plain Exception for the existing error path", e is Exception)
    }

    /**
     * The read-timeout budget must clear the old 60 s ceiling — the specific value that made a powerful
     * model look like it produced nothing. These requests are non-streaming and capped at 4096 tokens,
     * so a reasoning-class model writing a long answer passed 60 s and was killed mid-generation every
     * time. Pinned to the same number as Swift, or the two platforms give up at different points.
     */
    @Test
    fun requestTimeoutIsLongEnoughForALargeModel() {
        assertTrue(
            "a budget at or under the old 60 s read timeout reproduces the original bug",
            AiCoach.REQUEST_TIMEOUT_SECONDS > 60,
        )
        assertEquals(
            "Android and Swift must use the same budget",
            180L,
            AiCoach.REQUEST_TIMEOUT_SECONDS,
        )
    }
}
