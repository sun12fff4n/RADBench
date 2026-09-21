package com.benchmark.d1.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {
    @Test
    void chainReflectionLoadsMiddle() throws Exception {
        Plugin p = App.loadPlugin();
        assertNotNull(p);
        assertEquals("com.benchmark.d1.middle.ChainMiddlePlugin", p.getClass().getName());
    }

    @Test
    void chainReflectionReachesEnd() throws Exception {
        String result = App.runPlugin("hello");
        assertTrue(result.contains("ChainEnd:"), "Should contain output from chain-end plugin");
    }

    @Test
    void fullChainExecutesCorrectly() throws Exception {
        String result = App.runPlugin("test");
        assertEquals("ChainMiddle:ChainEnd:TEST", result);
    }
}
