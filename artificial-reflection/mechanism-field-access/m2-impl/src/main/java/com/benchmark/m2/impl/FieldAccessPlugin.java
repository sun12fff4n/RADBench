package com.benchmark.m2.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.m2.helper.PluginHelper;

public class FieldAccessPlugin implements Plugin {
    private String prefix = "default";
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return prefix + ":" + helper.transform(input);
    }
}
