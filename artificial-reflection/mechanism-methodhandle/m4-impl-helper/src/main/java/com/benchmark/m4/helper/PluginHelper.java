package com.benchmark.m4.helper;

public class PluginHelper {
    public String transform(String input) {
        return input.chars()
            .filter(c -> c != ' ')
            .collect(StringBuilder::new, StringBuilder::appendCodePoint, StringBuilder::append)
            .toString();
    }
}
