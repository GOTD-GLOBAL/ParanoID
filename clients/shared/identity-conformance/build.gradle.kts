import org.gradle.api.tasks.testing.Test
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.kotlin.multiplatform.library)
    alias(libs.plugins.cryptography)
}

kotlin {
    explicitApi()

    compilerOptions {
        allWarningsAsErrors.set(true)
    }

    jvm {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    android {
        namespace = "global.gotd.paranoid.identity.conformance"
        compileSdk = 36
        minSdk = 26

        withHostTest {}

        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    iosArm64()
    iosSimulatorArm64()
    iosX64()

    sourceSets {
        commonMain.dependencies {
            implementation(libs.cryptography.core)
            implementation(libs.cryptography.provider.optimal)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
        jvmMain.dependencies {
            implementation(libs.cryptography.provider.jdk.bc)
        }
        androidMain.dependencies {
            implementation(libs.cryptography.provider.jdk.bc)
        }
    }
}

cryptography {
    configureSwiftLinkerOpts = true
}

tasks.withType<Test>().configureEach {
    systemProperty("paranoid.repo.root", rootProject.layout.projectDirectory.asFile.absolutePath)
}
