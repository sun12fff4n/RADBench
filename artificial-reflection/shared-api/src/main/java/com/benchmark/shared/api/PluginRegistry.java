package com.benchmark.shared.api;

import java.util.Collections;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class PluginRegistry {
    private static final Map<String, Plugin> registry = new ConcurrentHashMap<>();

    public static void register(String name, Plugin plugin) {
        registry.put(name, plugin);
    }

    public static Plugin get(String name) {
        return registry.get(name);
    }

    public static Map<String, Plugin> getAll() {
        return Collections.unmodifiableMap(registry);
    }

    public static void clear() {
        registry.clear();
    }
}
