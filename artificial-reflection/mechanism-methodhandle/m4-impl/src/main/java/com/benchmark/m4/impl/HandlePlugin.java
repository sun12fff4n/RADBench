package com.benchmark.m4.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.m4.helper.PluginHelper;

public class HandlePlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "HandlePlugin:" + helper.transform(input);
    }
}
