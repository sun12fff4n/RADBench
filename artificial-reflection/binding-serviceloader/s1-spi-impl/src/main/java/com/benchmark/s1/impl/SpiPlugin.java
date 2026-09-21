package com.benchmark.s1.impl;

import com.benchmark.shared.api.Plugin;
import com.benchmark.s1.helper.SpiHelper;

public class SpiPlugin implements Plugin {
    private final SpiHelper helper = new SpiHelper();

    @Override
    public String execute(String input) {
        return "SpiPlugin:" + helper.enrich(input);
    }
}
