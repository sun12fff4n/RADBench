package com.benchmark.s1.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void serviceLoaderDiscoversPlugin() {
        List<Plugin> plugins = App.loadPlugins();
        assertFalse(plugins.isEmpty(), "ServiceLoader should discover at least one Plugin");
        assertEquals(1, plugins.size());
    }

    @Test
    void discoveredPluginIsCorrectType() {
        Plugin plugin = App.loadPlugins().get(0);
        assertEquals("com.benchmark.s1.impl.SpiPlugin", plugin.getClass().getName());
    }

    @Test
    void pluginExecutesWithTransitiveHelper() {
        String result = App.runAllPlugins("test");
        assertEquals("SpiPlugin:test:spi-enriched", result);
    }
}
