package com.benchmark.l2.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void pluginLoadedViaParamPassing() throws Exception {
        Plugin p = App.loadPlugin("com.benchmark.l2.impl.ParamPlugin");
        assertNotNull(p);
    }

    @Test
    void pluginExecutesCorrectly() throws Exception {
        String result = App.runPlugin("HELLO");
        assertEquals("ParamPlugin:hello", result);
    }

    @Test
    void pluginUsesTransitiveHelper() throws Exception {
        Plugin p = App.loadPlugin("com.benchmark.l2.impl.ParamPlugin");
        assertTrue(p.execute("TEST").contains("test"));
    }
}
