package com.benchmark.d2.right;

import com.benchmark.d2.common.CommonPlugin;

public class RightFacade {
    private final CommonPlugin plugin = new CommonPlugin();

    public String process(String input) {
        return "Right:" + plugin.execute(input);
    }
}
