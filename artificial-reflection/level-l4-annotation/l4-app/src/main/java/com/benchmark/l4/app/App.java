package com.benchmark.l4.app;

import com.benchmark.shared.api.Plugin;
import com.benchmark.l4.annotation.PluginBinding;

@PluginBinding("com.benchmark.l4.impl.AnnotatedPlugin")
public class App {

    public static Plugin loadPlugin() throws Exception {
        PluginBinding binding = App.class.getAnnotation(PluginBinding.class);
        if (binding == null) {
            throw new IllegalStateException("No @PluginBinding annotation found");
        }
        String className = binding.value();
        Class<?> clazz = Class.forName(className);
        return (Plugin) clazz.getDeclaredConstructor().newInstance();
    }

    public static String runPlugin(String input) throws Exception {
        return loadPlugin().execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello world"));
    }
}
