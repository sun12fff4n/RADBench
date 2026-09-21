package com.benchmark.s1.app;

import com.benchmark.shared.api.Plugin;
import java.util.ServiceLoader;
import java.util.List;
import java.util.stream.Collectors;

public class App {

    public static List<Plugin> loadPlugins() {
        return ServiceLoader.load(Plugin.class)
                .stream()
                .map(ServiceLoader.Provider::get)
                .collect(Collectors.toList());
    }

    public static String runAllPlugins(String input) {
        List<Plugin> plugins = loadPlugins();
        if (plugins.isEmpty()) {
            throw new IllegalStateException("No plugins discovered via ServiceLoader");
        }
        return plugins.stream()
                .map(p -> p.execute(input))
                .collect(Collectors.joining(", "));
    }

    public static void main(String[] args) {
        System.out.println(runAllPlugins("hello"));
    }
}
