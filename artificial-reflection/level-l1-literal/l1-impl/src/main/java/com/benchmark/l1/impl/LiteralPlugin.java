package com.benchmark.l1.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.l1.helper.PluginHelper;

public class LiteralPlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "LiteralPlugin:" + helper.transform(input);
    }
}
