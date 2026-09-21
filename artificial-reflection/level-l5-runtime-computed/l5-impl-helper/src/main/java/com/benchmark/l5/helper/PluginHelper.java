package com.benchmark.l5.helper;

public class PluginHelper {
    public String transform(String input) {
        return input.chars()
            .mapToObj(c -> String.valueOf((char)(c ^ 0x20)))
            .reduce("", String::concat);
    }
}
