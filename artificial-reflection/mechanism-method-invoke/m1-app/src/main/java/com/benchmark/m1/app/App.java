package com.benchmark.m1.app;

import com.benchmark.shared.api.Plugin;
import java.lang.reflect.Method;

public class App {
    public static Plugin loadPlugin() throws Exception {
        Class<?> clazz = Class.forName("com.benchmark.m1.impl.MethodInvokePlugin");
        return (Plugin) clazz.getDeclaredConstructor().newInstance();
    }

    public static String invokeViaReflection(String input) throws Exception {
        Class<?> clazz = Class.forName("com.benchmark.m1.impl.MethodInvokePlugin");
        Object instance = clazz.getDeclaredConstructor().newInstance();
        Method method = clazz.getMethod("execute", String.class);
        return (String) method.invoke(instance, input);
    }

    public static String runPlugin(String input) throws Exception {
        return invokeViaReflection(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello"));
    }
}
