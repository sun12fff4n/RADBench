package com.benchmark.m3.app;

import com.benchmark.shared.api.Plugin;
import org.junit.jupiter.api.Test;
import java.lang.reflect.Proxy;

import static org.junit.jupiter.api.Assertions.*;

class AppTest {
    @Test
    void proxyCreatedSuccessfully() throws Exception {
        Plugin p = App.createProxiedPlugin();
        assertNotNull(p);
        assertTrue(Proxy.isProxyClass(p.getClass()));
    }

    @Test
    void proxyDelegatesToTarget() throws Exception {
        String result = App.runPlugin("hello");
        assertEquals("ProxyPlugin:hello:5", result);
    }

    @Test
    void proxyImplementsPluginInterface() throws Exception {
        Plugin p = App.createProxiedPlugin();
        assertTrue(p instanceof Plugin);
    }
}
