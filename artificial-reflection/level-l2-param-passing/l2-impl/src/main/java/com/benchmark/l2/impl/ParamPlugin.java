package com.benchmark.l2.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.l2.helper.PluginHelper;

public class ParamPlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "ParamPlugin:" + helper.transform(input);
    }
}
