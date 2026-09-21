package com.benchmark.m2.app;

import com.benchmark.shared.api.Plugin;
import java.lang.reflect.Field;

public class App {
    public static Plugin loadAndConfigure(String prefix) throws Exception {
        Class<?> clazz = Class.forName("com.benchmark.m2.impl.FieldAccessPlugin");
        Object instance = clazz.getDeclaredConstructor().newInstance();

        Field field = clazz.getDeclaredField("prefix");
        field.setAccessible(true);
        field.set(instance, prefix);

        return (Plugin) instance;
    }

    public static String runPlugin(String input) throws Exception {
        return loadAndConfigure("FieldAccess").execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello"));
    }
}
