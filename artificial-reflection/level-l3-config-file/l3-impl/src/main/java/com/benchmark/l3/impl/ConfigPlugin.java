package com.benchmark.l3.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.l3.helper.PluginHelper;

public class ConfigPlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "ConfigPlugin:" + helper.transform(input);
    }
}
