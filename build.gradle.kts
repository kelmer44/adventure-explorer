import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm")
    id("org.jetbrains.compose")
}

group = "com.adventureexplorer"
version = "1.0-SNAPSHOT"

repositories {
    mavenCentral()
    maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
    google()
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation("org.luaj:luaj-jse:3.0.1")
}

compose.desktop {
    application {
        mainClass = "adventureexplorer.MainKt"

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Adventure Explorer"
            packageVersion = "1.0.0"

            // Include scripts directory in distribution
            appResourcesRootDir.set(project.layout.projectDirectory.dir("scripts"))
        }
    }
}
