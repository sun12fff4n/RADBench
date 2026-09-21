package com.benchmark.m3.app;

import com.benchmark.shared.api.Plugin;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Proxy;

public class App {
    public static Plugin createProxiedPlugin() throws Exception {
        Class<?> clazz = Class.forName("com.benchmark.m3.impl.ProxyTargetPlugin");
        Object target = clazz.getDeclaredConstructor().newInstance();
        InvocationHandler handler = (proxy, method, args) -> {
            return method.invoke(target, args);
        };
        return (Plugin) Proxy.newProxyInstance(
            Plugin.class.getClassLoader(),
            new Class<?>[]{Plugin.class},
            handler
        );
    }

    public static String runPlugin(String input) throws Exception {
        return createProxiedPlugin().execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello"));
    }
}
