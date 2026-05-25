pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Hosts `com.github.jeziellago:compose-markdown`, used to render
        // markdown in chat bubbles and briefing summaries. No mavenCentral
        // mirror exists for that artifact.
        maven { url = uri("https://jitpack.io") }
    }
}

rootProject.name = "RxCodeAndroid"
include(":app")
