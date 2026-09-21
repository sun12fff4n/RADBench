package com.benchmark.m1.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void pluginMethodInvokedReflectively() throws Exception {
        String result = App.invokeViaReflection("hello world");
        assertNotNull(result);
    }

    @Test
    void pluginExecutesCorrectly() throws Exception {
        String result = App.runPlugin("hello world");
        assertEquals("MethodInvokePlugin:hello_world", result);
    }

    @Test
    void pluginAlsoLoadableNormally() throws Exception {
        Plugin p = App.loadPlugin();
        assertEquals("MethodInvokePlugin:test", p.execute("test"));
    }
}
