// Kotlin + Java on the image's JDK 21 (no toolchain block on purpose: Gradle
// must use $JAVA_HOME, never auto-provision another JDK).
plugins {
    kotlin("jvm") version "2.4.21"
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
    testLogging { events("passed", "failed") }
}
