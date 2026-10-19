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
    implementation("javazoom:jlayer:1.0.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.8.1")
    testImplementation("junit:junit:4.13.2")
}

compose.desktop {
    application {
        mainClass = "adventureexplorer.MainKt"

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "Adventure Explorer"
            packageVersion = "1.0.0"

            macOS {
                iconFile.set(project.file("src/main/resources/icons/fedora.icns"))
            }
            windows {
                iconFile.set(project.file("src/main/resources/icons/fedora.ico"))
            }
            linux {
                iconFile.set(project.file("src/main/resources/icons/fedora.png"))
            }

            // Include scripts directory in distribution
            appResourcesRootDir.set(project.layout.projectDirectory.dir("scripts"))
        }
    }
}

// Developer helper: ./gradlew devcli --args="tree /path/to/game"
tasks.register<JavaExec>("devcli") {
    group = "application"
    description = "Headless resource dump tool for engine scripts"
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("adventureexplorer.DevCliKt")
}
