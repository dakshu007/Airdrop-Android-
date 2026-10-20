plugins {
    kotlin("jvm") version "2.2.0"
    application
}

group = "com.crossdrop"
version = "0.1.0"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

application {
    // Interop test tool used by CI; not shipped in the Android app.
    mainClass.set("com.crossdrop.core.cli.MainKt")
    applicationName = "crossdrop-cli"
}

tasks.test {
    useJUnitPlatform()
    systemProperty("crossdrop.vectors", rootDir.resolve("../../protocol/test-vectors/v1.json").absolutePath)
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
