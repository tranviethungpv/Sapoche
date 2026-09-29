import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
}

// Target Java 17 so the Android app module can consume this library
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    api("com.github.TeamNewPipe:NewPipeExtractor:v0.26.5")
    api("com.squareup.okhttp3:okhttp:5.5.0")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")

    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
