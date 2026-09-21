package com.benchmark.m2.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {

    @Test
    void fieldSetViaReflection() throws Exception {
        Plugin p = App.loadAndConfigure("TestPrefix");
        String result = p.execute("hello");
        assertTrue(result.startsWith("TestPrefix:"));
    }

    @Test
    void pluginExecutesCorrectly() throws Exception {
        String result = App.runPlugin("hello");
        assertEquals("FieldAccess:Hello", result);
    }

    @Test
    void defaultPrefixWithoutFieldAccess() throws Exception {
        Class<?> clazz = Class.forName("com.benchmark.m2.impl.FieldAccessPlugin");
        Plugin p = (Plugin) clazz.getDeclaredConstructor().newInstance();
        assertTrue(p.execute("test").startsWith("default:"));
    }
}
