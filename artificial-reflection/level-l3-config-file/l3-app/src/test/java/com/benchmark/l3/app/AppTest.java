package com.benchmark.l3.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void pluginLoadedFromConfig() throws Exception {
        Plugin p = App.loadPlugin();
        assertNotNull(p);
    }

    @Test
    void pluginIsCorrectType() throws Exception {
        Plugin p = App.loadPlugin();
        assertEquals("com.benchmark.l3.impl.ConfigPlugin", p.getClass().getName());
    }

    @Test
    void pluginExecutesCorrectly() throws Exception {
        String result = App.runPlugin("hello");
        assertEquals("ConfigPlugin:olleh", result);
    }
}
