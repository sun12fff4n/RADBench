package com.benchmark.m4.app;

import com.benchmark.shared.api.Plugin;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;

public class App {
    public static Plugin loadPlugin() throws Throwable {
        MethodHandles.Lookup lookup = MethodHandles.lookup();
        Class<?> clazz = Class.forName("com.benchmark.m4.impl.HandlePlugin");
        MethodHandle constructor = lookup.findConstructor(clazz, MethodType.methodType(void.class));
        return (Plugin) constructor.invoke();
    }

    public static String invokeViaHandle(String input) throws Throwable {
        MethodHandles.Lookup lookup = MethodHandles.lookup();
        Class<?> clazz = Class.forName("com.benchmark.m4.impl.HandlePlugin");
        MethodHandle constructor = lookup.findConstructor(clazz, MethodType.methodType(void.class));
        Object instance = constructor.invoke();
        MethodHandle executeHandle = lookup.findVirtual(clazz, "execute", MethodType.methodType(String.class, String.class));
        return (String) executeHandle.invoke(instance, input);
    }

    public static String runPlugin(String input) throws Throwable {
        return invokeViaHandle(input);
    }

    public static void main(String[] args) throws Throwable {
        System.out.println(runPlugin("hello"));
    }
}
