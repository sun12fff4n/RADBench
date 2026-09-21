package com.benchmark.l5.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void pluginLoadedViaComputedName() throws Exception {
        Plugin p = App.loadPlugin("ComputedPlugin");
        assertNotNull(p);
    }

    @Test
    void pluginExecutesCorrectly() throws Exception {
        String result = App.runPlugin("hello");
        assertEquals("ComputedPlugin:HELLO", result);
    }

    @Test
    void pluginUsesTransitiveHelper() throws Exception {
        Plugin p = App.loadPlugin("ComputedPlugin");
        assertTrue(p.execute("ABC").contains("abc"));
    }
}
