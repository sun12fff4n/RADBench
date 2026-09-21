package com.benchmark.l4.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.l4.helper.PluginHelper;

public class AnnotatedPlugin implements Plugin {
    private final PluginHelper helper = new PluginHelper();

    @Override
    public String execute(String input) {
        return "AnnotatedPlugin:" + helper.transform(input);
    }
}
