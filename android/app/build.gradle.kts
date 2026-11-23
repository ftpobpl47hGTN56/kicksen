import com.android.build.gradle.api.ApkVariantOutput
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val buildInstant = Instant.now()
val buildZone = ZoneId.systemDefault()
val buildDate = DateTimeFormatter.ofPattern("yyyy.MM.dd").format(buildInstant.atZone(buildZone))
val buildTime = DateTimeFormatter.ofPattern("HHmm").format(buildInstant.atZone(buildZone))
val buildVersionCode = (buildInstant.epochSecond / 60 - Instant.parse("2020-01-01T00:00:00Z").epochSecond / 60).toInt()
val buildVersionName = "${flutter.versionName}-kick-$buildDate-$buildTime"

android {
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
    namespace = "com.kicksen.chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.kicksen.chat"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = buildVersionCode
        versionName = buildVersionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    applicationVariants.configureEach {
        val variantName = name
        val apkName = "ChatsenKick-$buildVersionName-$buildVersionCode-$variantName.apk"
        outputs.configureEach {
            if (this is ApkVariantOutput) {
                outputFileName = apkName
            }
        }
        tasks.named("assemble${variantName.replaceFirstChar { it.uppercase() }}") {
            doLast {
                copy {
                    from(layout.buildDirectory.dir("outputs/apk/$variantName")) {
                        include(apkName)
                    }
                    into(rootProject.layout.buildDirectory.dir("app/outputs/flutter-apk"))
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
