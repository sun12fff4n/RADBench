package com.benchmark.m1.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.m1.helper.PluginHelper;

public class MethodInvokePlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "MethodInvokePlugin:" + helper.transform(input);
    }
}
