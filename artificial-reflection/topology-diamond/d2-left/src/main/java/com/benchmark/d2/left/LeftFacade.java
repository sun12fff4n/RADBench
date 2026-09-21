package com.benchmark.d2.left;

import com.benchmark.shared.api.Plugin;

public class LeftFacade {
    public String process(String input) {
        try {
            Class<?> clazz = Class.forName("com.benchmark.d2.common.CommonPlugin");
            Plugin plugin = (Plugin) clazz.getDeclaredConstructor().newInstance();
            return "Left:" + plugin.execute(input);
        } catch (Exception e) {
            throw new RuntimeException("Reflection failed", e);
        }
    }
}
