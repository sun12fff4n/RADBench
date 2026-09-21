package com.benchmark.l5.app;

import com.benchmark.shared.api.Plugin;

public class App {
    private static final String PACKAGE = "com.benchmark.l5";

    public static Plugin loadPlugin(String simpleName) throws Exception {
        String className = PACKAGE + ".impl." + simpleName;
        Class<?> clazz = Class.forName(className);
        return (Plugin) clazz.getDeclaredConstructor().newInstance();
    }

    public static String runPlugin(String input) throws Exception {
        return loadPlugin("ComputedPlugin").execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello"));
    }
}
