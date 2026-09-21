package com.benchmark.m2.helper;

public class PluginHelper {
    public String transform(String input) {
        return input.substring(0, 1).toUpperCase() + input.substring(1);
    }
}
