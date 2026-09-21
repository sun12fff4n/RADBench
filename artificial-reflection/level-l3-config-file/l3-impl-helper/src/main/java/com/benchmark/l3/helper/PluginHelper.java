package com.benchmark.l3.helper;

public class PluginHelper {
    public String transform(String input) {
        return new StringBuilder(input).reverse().toString();
    }
}
