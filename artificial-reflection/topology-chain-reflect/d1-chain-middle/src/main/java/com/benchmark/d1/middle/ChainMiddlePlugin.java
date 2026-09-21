package com.benchmark.d1.middle;

import com.benchmark.shared.api.Plugin;

public class ChainMiddlePlugin implements Plugin {
    @Override
    public String execute(String input) {
        try {
            Class<?> clazz = Class.forName("com.benchmark.d1.end.ChainEndPlugin");
            Plugin endPlugin = (Plugin) clazz.getDeclaredConstructor().newInstance();
            return "ChainMiddle:" + endPlugin.execute(input);
        } catch (Exception e) {
            throw new RuntimeException("Chain reflection failed", e);
        }
    }
}
