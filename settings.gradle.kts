pluginManagement {
    repositories {
        gradlePluginPortal()
        maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
        google()
    }

    plugins {
        kotlin("jvm") version "1.9.23"
        id("org.jetbrains.compose") version "1.6.1"
    }
}

rootProject.name = "adventure-explorer"
