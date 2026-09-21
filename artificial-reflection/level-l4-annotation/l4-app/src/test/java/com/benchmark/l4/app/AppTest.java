package com.benchmark.l4.app;

import com.benchmark.shared.api.Plugin;
import com.benchmark.l4.annotation.PluginBinding;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {
    @Test
    void annotationPresent() {
        PluginBinding binding = App.class.getAnnotation(PluginBinding.class);
        assertNotNull(binding);
        assertEquals("com.benchmark.l4.impl.AnnotatedPlugin", binding.value());
    }

    @Test
    void pluginLoadedViaAnnotation() throws Exception {
        Plugin p = App.loadPlugin();
        assertNotNull(p);
        assertEquals("com.benchmark.l4.impl.AnnotatedPlugin", p.getClass().getName());
    }

    @Test
    void pluginExecutesCorrectly() throws Exception {
        String result = App.runPlugin("hello world");
        assertEquals("AnnotatedPlugin:HELLO-WORLD", result);
    }
}
