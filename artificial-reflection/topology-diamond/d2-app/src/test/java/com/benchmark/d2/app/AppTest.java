package com.benchmark.d2.app;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AppTest {
    @Test
    void leftPathUsesReflection() {
        String result = App.runLeft("HELLO");
        assertEquals("Left:Common:hello", result);
    }

    @Test
    void rightPathUsesStaticBinding() {
        String result = App.runRight("HELLO");
        assertEquals("Right:Common:hello", result);
    }

    @Test
    void diamondProducesSameResult() {
        // Both paths go through CommonPlugin, should produce same transformation
        String left = App.runLeft("Test");
        String right = App.runRight("Test");
        assertTrue(left.contains("Common:test"));
        assertTrue(right.contains("Common:test"));
    }

    @Test
    void bothPathsExecuteTogether() {
        String result = App.runBoth("Hi");
        assertEquals("Left:Common:hi | Right:Common:hi", result);
    }
}
