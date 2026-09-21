package com.benchmark.l3.app;

import com.benchmark.shared.api.Plugin;
import java.io.InputStream;
import java.util.Properties;

public class App {
    public static Plugin loadPlugin() throws Exception {
        Properties props = new Properties();
        try (InputStream is = App.class.getClassLoader().getResourceAsStream("plugin.properties")) {
            if (is == null) throw new IllegalStateException("plugin.properties not found");
            props.load(is);
        }
        String className = props.getProperty("plugin.class");
        Class<?> clazz = Class.forName(className);
        return (Plugin) clazz.getDeclaredConstructor().newInstance();
    }

    public static String runPlugin(String input) throws Exception {
        return loadPlugin().execute(input);
    }

    public static void main(String[] args) throws Exception {
        System.out.println(runPlugin("hello"));
    }
}
