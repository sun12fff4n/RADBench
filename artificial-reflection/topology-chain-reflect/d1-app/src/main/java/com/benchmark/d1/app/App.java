package com.benchmark.d1.app;

import com.benchmark.shared.api.Plugin;

public class App {
    public static Plugin loadPlugin() throws Exception {
        Class<?> clazz = Class.forName("com.benchmark.d1.middle.ChainMiddlePlugin");
        return (Plugin) clazz.getDeclaredConstructor().newInstance();
    }

    public static String runPlugin(String input) throws Exception {
        return loadPlugin().execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello"));
    }
}
