package com.benchmark.d1.end;

import com.benchmark.shared.api.Plugin;

public class ChainEndPlugin implements Plugin {
    @Override
    public String execute(String input) {
        return "ChainEnd:" + input.toUpperCase();
    }
}
