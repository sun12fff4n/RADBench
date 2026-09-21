package com.benchmark.m3.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.m3.helper.PluginHelper;

public class ProxyTargetPlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "ProxyPlugin:" + helper.transform(input);
    }
}
