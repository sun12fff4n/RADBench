package com.benchmark.d2.common;

import com.benchmark.shared.api.Plugin;

public class CommonPlugin implements Plugin {
    @Override
    public String execute(String input) {
        return "Common:" + input.toLowerCase();
    }
}
