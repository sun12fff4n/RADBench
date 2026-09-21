package com.benchmark.s2.driver;

import com.benchmark.shared.api.Plugin;
import com.benchmark.shared.api.PluginRegistry;
import com.benchmark.s2.dep.DriverCodec;

public class AutoRegisterPlugin implements Plugin {

    private final DriverCodec codec = new DriverCodec();

    static {
        PluginRegistry.register("auto", new AutoRegisterPlugin());
    }

    @Override
    public String execute(String input) {
        return "AutoPlugin:" + codec.encode(input);
    }
}
