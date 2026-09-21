package com.benchmark.l2.app;

import com.benchmark.shared.api.Plugin;

public class App {

    public static Plugin loadPlugin(String className) throws Exception {
        Class<?> clazz = Class.forName(className);
        return (Plugin) clazz.getDeclaredConstructor().newInstance();
    }

    public static String runPlugin(String input) throws Exception {
        return loadPlugin("com.benchmark.l2.impl.ParamPlugin").execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("HELLO"));
    }
}
