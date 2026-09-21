package com.benchmark.l1.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void pluginLoadedViaForName() throws Exception {
        Plugin plugin = App.loadPlugin();
        assertNotNull(plugin);
        assertEquals("com.benchmark.l1.impl.LiteralPlugin", plugin.getClass().getName());
    }

    @Test
    void pluginExecutesCorrectly() throws Exception {
        String result = App.runPlugin("test");
        assertEquals("LiteralPlugin:TEST", result);
    }

    @Test
    void pluginUsesTransitiveHelper() throws Exception {
        String result = App.runPlugin("hello");
        assertTrue(result.contains("HELLO"), "Should contain uppercased input from PluginHelper");
    }
}
