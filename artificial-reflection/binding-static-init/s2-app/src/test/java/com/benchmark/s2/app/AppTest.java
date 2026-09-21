package com.benchmark.s2.app;

import com.benchmark.shared.api.Plugin;
import com.benchmark.shared.api.PluginRegistry;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import static org.junit.jupiter.api.Assertions.*;

@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AppTest {

    @Test
    @Order(1)
    void registryEmptyBeforeDriverLoad() {
        PluginRegistry.clear();
        assertNull(PluginRegistry.get("auto"), "Registry should be empty before Class.forName");
    }

    @Test
    @Order(2)
    void driverRegistersViaStaticInit() throws Exception {
        App.loadDriver();
        assertNotNull(PluginRegistry.get("auto"), "Plugin should be registered after Class.forName");
    }

    @Test
    @Order(3)
    void registeredPluginIsCorrectType() {
        Plugin plugin = PluginRegistry.get("auto");
        assertNotNull(plugin);
        assertEquals("com.benchmark.s2.driver.AutoRegisterPlugin", plugin.getClass().getName());
    }

    @Test
    @Order(4)
    void pluginExecutesWithTransitiveDep() throws Exception {
        String result = App.runPlugin("test");
        assertEquals("AutoPlugin:encoded(test)", result);
    }
}
