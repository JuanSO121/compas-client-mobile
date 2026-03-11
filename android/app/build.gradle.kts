// android/app/build.gradle.kts

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_voice_robot"
    compileSdk = 36

    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.example.flutter_voice_robot"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"

        multiDexEnabled = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("debug")
        }
        debug {
            isMinifyEnabled = false
            isDebuggable = true
        }
    }

    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/license.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/notice.txt",
                "META-INF/ASL2.0",
                "META-INF/*.kotlin_module"
            )
        }
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

flutter {
    source = "../.."
}



dependencies {
    // ═══════════════════════════════════════════════════════
    // ✅ GOOGLE AI EDGE (IA LOCAL - NPU)
    // ═══════════════════════════════════════════════════════
    implementation("com.google.mediapipe:tasks-genai:0.10.14")

    // ═══════════════════════════════════════════════════════
    // ✅ GOOGLE PLAY SERVICES (BÁSICO)
    // ═══════════════════════════════════════════════════════
    implementation("com.google.android.gms:play-services-base:18.5.0")

    // ═══════════════════════════════════════════════════════
    // ✅ KOTLIN
    // ═══════════════════════════════════════════════════════
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")

    // ═══════════════════════════════════════════════════════
    // ✅ ANDROIDX
    // ═══════════════════════════════════════════════════════
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.multidex:multidex:2.0.1")

    // ═══════════════════════════════════════════════════════
    // ✅ UTILIDADES
    // ═══════════════════════════════════════════════════════
    implementation("com.google.code.gson:gson:2.10.1")

    // ← Unity
    implementation(project(":unityLibrary"))
}

// ═══════════════════════════════════════════════════════
// ✅ RESOLVER CONFLICTOS DE VERSIONES
// ═══════════════════════════════════════════════════════
configurations.all {
    resolutionStrategy {
        force("com.google.android.gms:play-services-basement:18.5.0")
        force("com.google.android.gms:play-services-base:18.5.0")
        force("androidx.core:core:1.13.1")
    }
}

