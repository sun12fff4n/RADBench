package com.benchmark.d2.app;

import com.benchmark.d2.left.LeftFacade;
import com.benchmark.d2.right.RightFacade;

public class App {
    public static String runLeft(String input) {
        return new LeftFacade().process(input);
    }

    public static String runRight(String input) {
        return new RightFacade().process(input);
    }

    public static String runBoth(String input) {
        return runLeft(input) + " | " + runRight(input);
    }

    public static void main(String[] args) {
        System.out.println(runBoth("Hello World"));
    }
}
