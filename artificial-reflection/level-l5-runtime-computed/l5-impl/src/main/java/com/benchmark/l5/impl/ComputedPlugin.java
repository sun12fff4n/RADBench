package com.benchmark.l5.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.l5.helper.PluginHelper;

public class ComputedPlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "ComputedPlugin:" + helper.transform(input);
    }
}
