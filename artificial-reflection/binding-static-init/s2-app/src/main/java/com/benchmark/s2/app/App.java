package com.benchmark.s2.app;

import com.benchmark.shared.api.Plugin;
import com.benchmark.shared.api.PluginRegistry;

public class App {

    public static void loadDriver() throws ClassNotFoundException {
        Class.forName("com.benchmark.s2.driver.AutoRegisterPlugin");
    }

    public static String runPlugin(String input) throws Exception {
        loadDriver();
        Plugin plugin = PluginRegistry.get("auto");
        if (plugin == null) {
            throw new IllegalStateException("Plugin 'auto' not found in registry after driver load");
        }
        return plugin.execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello"));
    }
}
