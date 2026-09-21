package com.benchmark.m4.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void pluginLoadedViaMethodHandle() throws Throwable {
        Plugin p = App.loadPlugin();
        assertNotNull(p);
    }

    @Test
    void methodInvokedViaHandle() throws Throwable {
        String result = App.invokeViaHandle("hello world");
        assertEquals("HandlePlugin:helloworld", result);
    }

    @Test
    void pluginExecutesCorrectly() throws Throwable {
        String result = App.runPlugin("a b c");
        assertEquals("HandlePlugin:abc", result);
    }
}
